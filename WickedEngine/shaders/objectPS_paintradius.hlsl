#define OBJECTSHADER_LAYOUT_SHADOW_TEX
#define OBJECTSHADER_USE_COLOR
#include "objectHF.hlsli"
#include "ShaderInterop_Renderer.h"

[earlydepthstencil]
float4 main(PixelInput PSIn) : SV_TARGET
{
	const float2 pixel = (xPaintRadUVSET == 0 ? PSIn.uvsets.xy : PSIn.uvsets.zw) * xPaintRadResolution;

	const float2x2 rot = float2x2(
		cos(xPaintRadBrushRotation), -sin(xPaintRadBrushRotation),
		sin(xPaintRadBrushRotation), cos(xPaintRadBrushRotation)
		);
	const float2 diff = mul(xPaintRadCenter - pixel, rot);

	float dist = 0;
	switch (xPaintRadBrushShape)
	{
	default:
	case 0:
		dist = length(diff);
		break;
	case 1:
		dist = max(abs(diff.x), abs(diff.y));
		break;
	}

	float shape = dist - xPaintRadRadius;
	float3 color = shape < 0 ? float3(0, 0, 0) : float3(1, 1, 1);
	float alpha = 1 - saturate(abs(shape) * 0.25f);

	return float4(color, alpha);
}
