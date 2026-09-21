//
//  CanvasShaders.metal
//  Paint All the Time
//
//  Created by Denis Kolchev on 18.09.2026.
//

#include <metal_stdlib>
using namespace metal;

struct StrokeVertex {
    float2 position;
    float4 color;
};

struct VertexOutput {
    float4 position [[position]];
    float4 color;
};

vertex VertexOutput strokeVertex(
    uint vertexID [[vertex_id]],
    const device StrokeVertex* vertices [[buffer(0)]],
    constant float2& canvasSize [[buffer(1)]]
) {
    StrokeVertex input = vertices[vertexID];

    float2 ndc = float2(
        2.0 * input.position.x / canvasSize.x - 1.0,
        1.0 - 2.0 * input.position.y / canvasSize.y
    );

    VertexOutput output;
    output.position = float4(ndc, 0.0, 1.0);
    output.color = input.color;

    return output;
}

fragment float4 strokeFragment(
    VertexOutput input [[stage_in]]
) {
    return input.color;
}
