#include "globals.hlsli"
#include "volumetricCloudsHF.hlsli"
#include "skyAtmosphere.hlsli"
#include "ShaderInterop_Postprocess.h"

PUSHCONSTANT(postprocess, PostProcess);

Texture3D<float4> texture_shapeNoise : register(t0);
Texture3D<float4> texture_detailNoise : register(t1);
Texture2D<float4> texture_curlNoise : register(t2);
Texture2D<float4> texture_weatherMap : register(t3);

RWTexture2D<float3> texture_render : register(u0);

static const float2 sampleCountMinMax = float2(16.0, 32.0); // Based on sun angle, more angle more samples

void VolumetricShadowMap(out float3 result, in AtmosphereParameters atmosphere, float3 worldPosition, float3 sunDirection,
		float tMin, float tMax, float3 windOffset, float3 windDirection, float2 coverageWindOffset)
{
	float nearDepth = 0.0;
	float3 extinctionAccumulation = 0.0f;
	float extinctionAccumulationCount = 0.0f;
	float3 maxOpticalDepth = 0.0f;

	float3 planetSurfaceNormal = normalize(GetCamera().position - (atmosphere.planetCenter * SKY_UNIT_TO_M));
	float NdotL = saturate(dot(planetSurfaceNormal, sunDirection));
	float sampleCount = lerp(sampleCountMinMax.y, sampleCountMinMax.x, NdotL);
	
	const float shadowLength = tMax - tMin;
	const float delta = shadowLength / sampleCount; // Since our samples our linear this stays constant
	
	for (float s = 0.0f; s < sampleCount; s += 1.0)
	{
		// Linear Distribution
		float t = (s + 1.0f) / sampleCount;
		
		float shadowSampleT = shadowLength * t;
		float3 samplePoint = worldPosition + sunDirection * shadowSampleT; // Step futher towards the light

		float heightFraction = GetHeightFractionForPoint(atmosphere, samplePoint);
		if (heightFraction < 0.0 || heightFraction > 1.0)
		{
			break;
		}
		
		float3 weatherData = SampleWeather(texture_weatherMap, samplePoint, heightFraction, coverageWindOffset);
		if (weatherData.r < 0.25)
		{
			continue;
		}

		float shadowCloudDensity = SampleCloudDensity(texture_shapeNoise, texture_detailNoise, texture_curlNoise, samplePoint, heightFraction, weatherData, windOffset, windDirection, 0.0f, true);

		float3 shadowExtinction = GetWeather().volumetric_clouds.ExtinctionCoefficient * shadowCloudDensity;
		
		if (any(shadowExtinction > 0.0f))
		{
			nearDepth = max(shadowSampleT, nearDepth); // If there exists extinction "push" the near depth futher
			extinctionAccumulationCount += 1.0;
		}
		
		extinctionAccumulation += shadowExtinction;
		maxOpticalDepth += shadowExtinction * delta;
	}

	const float averageGreyExtinction = dot(extinctionAccumulation / max(extinctionAccumulationCount, 1.0f), 1.0f / 3.0f);
	const float maxGreyOpticalDepth = dot(maxOpticalDepth, 1.0f / 3.0f);

	// Values can get to big for the assigned texture, so we pack this into kilometer type
	const bool miss = nearDepth == 0.0;
	const float frontDepth = miss ? tMax * M_TO_SKY_UNIT : (tMin + nearDepth) * M_TO_SKY_UNIT;

	result = float3(frontDepth, averageGreyExtinction, maxGreyOpticalDepth);
}

[numthreads(POSTPROCESS_BLOCKSIZE, POSTPROCESS_BLOCKSIZE, 1)]
void main(uint3 DTid : SV_DispatchThreadID, uint3 GTid : SV_GroupThreadID, uint3 Gid : SV_GroupID, uint groupIndex : SV_GroupIndex)
{
	const float2 uv = (DTid.xy + 0.5) * postprocess.resolution_rcp;

	const float nearDepth = 1.0f;
	float3 nearPlaneWorldPosition = reconstruct_position(uv, nearDepth, GetFrame().cloudShadowLightSpaceMatrixInverse);
	
	// Setup for shadow capture:
	float3 rayOrigin = nearPlaneWorldPosition;
	float3 rayDirection = GetSunDirection();

	float3 result = float3(GetFrame().cloudShadowFarPlaneKm, 0.0, 0.0);
	
	AtmosphereParameters parameters = GetWeather().atmosphere;
		
	float planetRadius = parameters.bottomRadius * SKY_UNIT_TO_M;
	float3 planetCenterWorld = parameters.planetCenter * SKY_UNIT_TO_M;

	const float cloudBottomRadius = planetRadius + GetWeather().volumetric_clouds.CloudStartHeight;
	const float cloudTopRadius = planetRadius + GetWeather().volumetric_clouds.CloudStartHeight + GetWeather().volumetric_clouds.CloudThickness;
        
	float2 tTopSolutions = RaySphereIntersect(rayOrigin, rayDirection, planetCenterWorld, cloudTopRadius);
	if (tTopSolutions.x > 0.0 || tTopSolutions.y > 0.0) // Only calculate if any solutions are visible on screen!
	{
		float tMin = -FLT_MAX;
		float tMax = -FLT_MAX;
		
		float2 tBottomSolutions = RaySphereIntersect(rayOrigin, rayDirection, planetCenterWorld, cloudBottomRadius);
		if (tBottomSolutions.x > 0.0 || tBottomSolutions.y > 0.0)
		{
            // If we see both intersections on the screen, keep the min closest, otherwise the max furthest
			float tempTop = all(tTopSolutions > 0.0f) ? min(tTopSolutions.x, tTopSolutions.y) : max(tTopSolutions.x, tTopSolutions.y);
			float tempBottom = all(tBottomSolutions > 0.0f) ? min(tBottomSolutions.x, tBottomSolutions.y) : max(tBottomSolutions.x, tBottomSolutions.y);
                
            // But if we can see the bottom of the layer, make sure we use the camera view or the highest top layer intersection
			if (all(tBottomSolutions > 0.0f))
			{
				tempTop = max(0.0f, min(tTopSolutions.x, tTopSolutions.y));
			}

			tMin = min(tempBottom, tempTop);
			tMax = max(tempBottom, tempTop);
		}
		else
		{
			tMin = tTopSolutions.x;
			tMax = tTopSolutions.y;
		}
            
		tMin = max(0.0, tMin);
		tMax = max(0.0, tMax);
			
		float3 worldPositionClosestToCloudLayer = rayOrigin + rayDirection * tMin; // Determined by tMin

		// Wind animation offsets
		float3 windDirection = float3(cos(GetWeather().volumetric_clouds.WindAngle), -GetWeather().volumetric_clouds.WindUpAmount, sin(GetWeather().volumetric_clouds.WindAngle));
		float3 windOffset = GetWeather().volumetric_clouds.WindSpeed * GetWeather().volumetric_clouds.AnimationMultiplier * windDirection * GetFrame().time;

		float2 coverageWindDirection = float2(cos(GetWeather().volumetric_clouds.CoverageWindAngle), sin(GetWeather().volumetric_clouds.CoverageWindAngle));
		float2 coverageWindOffset = GetWeather().volumetric_clouds.CoverageWindSpeed * GetWeather().volumetric_clouds.AnimationMultiplier * coverageWindDirection * GetFrame().time;

		// Render
		VolumetricShadowMap(result, parameters, worldPositionClosestToCloudLayer, GetSunDirection(), tMin, tMax, windOffset, windDirection, coverageWindOffset);
	}

	// Output
	texture_render[DTid.xy] = result;
}
