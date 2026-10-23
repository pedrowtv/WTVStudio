// Shaders Metal guardados como texto e compilados em tempo de execução (D9).
// Sem Metal Toolchain nesta máquina; ver docs/AMBIENTE.md.

public enum ShaderSources {
    public static let compositor = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct LayerUniforms {
        float4 rect;        // x, y, w, h normalizados no bus (origem canto superior esquerdo)
        float4 crop;        // x, y, w, h em coordenadas da textura
        float4 colour;      // cor sólida / cor do dip
        float  opacity;
        int    kind;        // 0 bgra, 1 nv12, 2 cor, 3 barras, 4 padrão de teste, 5 sincronismo, 6 preto
        int    wipeMode;    // 0 nenhum, 1 esq, 2 dir, 3 cima, 4 baixo, 5 caixa, 6 círculo, 7 diagUp, 8 diagDown
        float  wipeProgress;
        float  wipeSoftness;
        float  time;        // segundos (padrões animados)
        int    flashOn;
        int    fullRange;   // nv12: 1 full, 0 video range
    };

    struct VOut {
        float4 pos [[position]];
        float2 uv;
        float2 busUV;
    };

    vertex VOut layerVertex(uint vid [[vertex_id]], constant LayerUniforms& u [[buffer(0)]]) {
        float2 quad[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
        float2 p = quad[vid];
        float2 bus = float2(u.rect.x + p.x * u.rect.z, u.rect.y + p.y * u.rect.w);
        VOut o;
        o.pos = float4(bus.x * 2.0 - 1.0, 1.0 - bus.y * 2.0, 0.0, 1.0);
        o.uv = float2(u.crop.x + p.x * u.crop.z, u.crop.y + p.y * u.crop.w);
        o.busUV = bus;
        return o;
    }

    static float wipeCoverage(float2 b, constant LayerUniforms& u) {
        if (u.wipeMode == 0) return 1.0;
        float p = u.wipeProgress;
        float s = max(u.wipeSoftness, 0.0005);
        float d;
        switch (u.wipeMode) {
            case 1: d = p - b.x; break;                       // revela da esquerda
            case 2: d = p - (1.0 - b.x); break;               // da direita
            case 3: d = p - b.y; break;                       // de cima
            case 4: d = p - (1.0 - b.y); break;               // de baixo
            case 5: { float2 c = abs(b - 0.5) * 2.0; d = p - max(c.x, c.y); break; }   // caixa
            case 6: { float2 c = (b - 0.5) * float2(16.0/9.0, 1.0); d = p * 1.03 - length(c); break; } // círculo
            case 7: d = p * 2.0 - (b.x + (1.0 - b.y)); break; // diagonal para cima
            default: d = p * 2.0 - (b.x + b.y); break;        // diagonal para baixo
        }
        return smoothstep(-s, s, d);
    }

    static float3 smpteBars(float2 uv) {
        // 75 % SMPTE: 7 barras em cima (2/3), faixa de referência em baixo
        const float3 top[7] = { float3(0.75), float3(0.75,0.75,0), float3(0,0.75,0.75), float3(0,0.75,0),
                                float3(0.75,0,0.75), float3(0.75,0,0), float3(0,0,0.75) };
        if (uv.y < 0.667) {
            int i = clamp(int(uv.x * 7.0), 0, 6);
            return top[i];
        } else if (uv.y < 0.75) {
            int i = clamp(int(uv.x * 7.0), 0, 6);
            const float3 mid[7] = { float3(0,0,0.75), float3(0.075), float3(0.75,0,0.75), float3(0.075),
                                    float3(0,0.75,0.75), float3(0.075), float3(0.75) };
            return mid[i];
        } else {
            if (uv.x < 0.125) return float3(0.0, 0.129, 0.298);
            if (uv.x < 0.25)  return float3(1.0);
            if (uv.x < 0.375) return float3(0.196, 0.0, 0.416);
            if (uv.x < 0.625) return float3(0.075);
            if (uv.x < 0.6875) return float3(0.035);
            if (uv.x < 0.75)  return float3(0.075);
            if (uv.x < 0.8125) return float3(0.115);
            return float3(0.075);
        }
    }

    static float3 testPattern(float2 uv, float t) {
        float3 c = float3(0.12, 0.13, 0.16);
        float2 g = fract(uv * float2(16.0, 9.0));
        float line = step(0.97, g.x) + step(0.97, g.y);
        c += line * 0.25;
        // círculo central
        float2 d = (uv - 0.5) * float2(16.0/9.0, 1.0);
        float r = length(d);
        c = mix(c, float3(0.9), smoothstep(0.012, 0.0, abs(r - 0.42)));
        // caixa em movimento (verifica cadência)
        float x = fract(t * 0.2);
        float2 bx = float2(x * 0.9 + 0.05, 0.9);
        if (abs(uv.x - bx.x) < 0.03 && abs(uv.y - bx.y) < 0.05) c = float3(1.0, 0.6, 0.0);
        // barra que se move a cada frame (1 px por tick a 60 Hz seria ténue; 10 %/s)
        float y = fract(t);
        if (abs(uv.y - y) < 0.004) c = float3(0.0, 1.0, 0.4);
        return c;
    }

    fragment float4 layerFragment(VOut in [[stage_in]],
                                  constant LayerUniforms& u [[buffer(0)]],
                                  texture2d<float> tex0 [[texture(0)]],
                                  texture2d<float> tex1 [[texture(1)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = float4(0, 0, 0, 1);
        switch (u.kind) {
            case 0: c = tex0.sample(s, in.uv); break;
            case 1: {
                float y = tex0.sample(s, in.uv).r;
                float2 cbcr = tex1.sample(s, in.uv).rg - 0.5;
                if (u.fullRange == 0) { y = (y - 16.0/255.0) * (255.0/219.0); cbcr *= 255.0/224.0; }
                float r = y + 1.5748 * cbcr.y;
                float g = y - 0.1873 * cbcr.x - 0.4681 * cbcr.y;
                float b = y + 1.8556 * cbcr.x;
                c = float4(saturate(float3(r, g, b)), 1.0);
                break;
            }
            case 2: c = u.colour; break;
            case 3: c = float4(smpteBars(in.uv), 1.0); break;
            case 4: c = float4(testPattern(in.uv, u.time), 1.0); break;
            case 5: c = u.flashOn ? float4(1.0) : float4(0.0, 0.0, 0.0, 1.0); break;
            default: c = float4(0, 0, 0, 1); break;
        }
        float a = c.a * u.opacity * wipeCoverage(in.busUV, u);
        return float4(c.rgb * a, a); // alfa pré-multiplicado
    }

    // BGRA → NV12 (BT.709, video range). Cada thread trata um bloco 2×2.
    kernel void bgraToNV12(texture2d<float, access::read> src [[texture(0)]],
                           texture2d<float, access::write> yTex [[texture(1)]],
                           texture2d<float, access::write> cbcrTex [[texture(2)]],
                           uint2 gid [[thread_position_in_grid]]) {
        uint2 p = gid * 2;
        if (p.x + 1 >= src.get_width() || p.y + 1 >= src.get_height()) return;
        float3 sumYuv = float3(0.0);
        for (uint dy = 0; dy < 2; dy++) {
            for (uint dx = 0; dx < 2; dx++) {
                uint2 q = p + uint2(dx, dy);
                float3 rgb = src.read(q).rgb;
                float yl = 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b;
                float cb = (rgb.b - yl) / 1.8556;
                float cr = (rgb.r - yl) / 1.5748;
                float yv = 16.0/255.0 + yl * 219.0/255.0;
                yTex.write(float4(yv), q);
                sumYuv += float3(0.0, cb, cr);
            }
        }
        float2 cbcr = 128.0/255.0 + sumYuv.yz * 0.25 * 224.0/255.0;
        cbcrTex.write(float4(cbcr, 0.0, 0.0), gid);
    }
    """#
}
