// Black Hole Raymarching Shader
// Based on Johan Svensson. https://medium.com/dotcrossdot
// Raymarching setup based on http://flafla2.github.io/2016/10/01/raymarching.html
//
// Hybrid lensing: original artistic lerp near the hole, physically-based
// deflection at distance for correct Einstein-ring behavior.
// Soft black-hole gradient via fremap + _HoleThickness (original approach).

Shader "Kit/BlackHoleRaymarchingModified"
{
    Properties
    {
        [HDR]_BlackHoleColor ("Black Hole Color", Color) = (0,0,0,1)
        _SchwarzschildRadius ("Schwarzschild Radius", Float) = 0.5
        _SpaceDistortion ("Space Distortion", Float) = 4.069

        [Header(Accretion Disk)]
        _AccretionDiskColor ("Color (Alpha = Hue Shift)", Color) = (1,1,1,1)
        _AccretionDiskRadius ("Disk Outer Radius", Range(1, 30)) = 6.0
        _AccretionDiskThickness ("Thickness", Float) = 1
        _AccretionDiskIntensity ("Intensity", Float) = 0.5
        _AcrretionDiskPulses ("Pulses", Range(0,35)) = 2.50
        _DopplerStrength ("Doppler Beaming", Range(0,2)) = 0.8
        _Noise ("Noise Texture", 2D) = "" {}

        [Header(Raymarching)]
        _RaymarchIterations ("Iterations", Range(1, 512)) = 162
        _Epsilon ("Epsilon", Float) = 0.01
        _StepSize ("Step Size", Float) = 0.005
        _Offset ("Center Offset", Vector) = (0, 0, 0)
        _HoleThickness ("Hole Thickness", Range(0,1)) = 0.01

        [Header(Background)]
        [PowerSlider(5.0)]_BGIntensity ("Background Intensity", Range(0,10)) = 0.4
        [PowerSlider(5.0)]_CubeIntensity ("Sky Cube Intensity", Range(0,10)) = 0.6
        [PowerSlider(2.0)]_RefractionIntensity ("Refraction Intensity", Range(0,10)) = 0.2
        [PowerSlider(3.0)]_RefractionLevel ("Refraction Level", Range(0,20)) = 0.2
        _HueShiftBG ("Hue Shift Background", Range(0,7)) = 1.00
        [PowerSlider(5.0)]_ScaleBG ("Scale BG", Range(0,20)) = 1.00
        [Toggle] _MatcapUVs ("Toggle Matcap Mode", Float) = 1
        _ScaleMatcapBG ("Scale Matcap BG", Range(0,100)) = 1.00
        _SkyCube ("Skycube", Cube) = "defaulttexture" {}

        [Header(Photon Ring)]
        _PhotonRingIntensity ("Photon Ring Glow", Range(0,5)) = 1.0
        _PhotonRingWidth ("Photon Ring Width", Range(0.01, 2.0)) = 0.316
        [Toggle] _PhotonRingMatchDisk ("Use Accretion Disk Colors", Float) = 0
    }

    SubShader
    {
        Tags { "RenderType" = "Transparent" "Queue" = "Transparent" }
        GrabPass { "_GrabdTexture" }

        // Z-prepass so transparent depth is written correctly.
        Pass
        {
            Blend Zero One
            ZWrite On
            Cull Off
        }

        Pass
        {
            Blend SrcAlpha OneMinusSrcAlpha
            ZWrite Off
            Cull Off

            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma exclude_renderers gles
            #include "UnityCG.cginc"

            // GLSL compatibility macros
            #define iTime         _Time.y
            #define iResolution   _ScreenParams
            #define vec2          float2
            #define vec3          float3
            #define vec4          float4
            #define mix           lerp
            #define fract         frac
            #define mod(x,y)      ((x) - (y) * floor((x) / (y)))
            #define IN_RANGE(x,a,b) (((x) > (a)) && ((x) < (b)))

            #define PI  3.14159265
            #define TAU 6.28318530718

            // Material properties
            uniform sampler2D _Noise;
            float4            _Noise_ST;
            float             _SpaceDistortion;
            float             _SchwarzschildRadius;
            float4            _AccretionDiskColor;
            float4            _BlackHoleColor;
            float             _AccretionDiskRadius;
            float             _AccretionDiskThickness;
            float             _AccretionDiskIntensity;
            sampler2D         _GrabdTexture;
            float             _Epsilon;
            float             _StepSize;
            float3            _Offset;
            float             _HoleThickness;
            float             _AcrretionDiskPulses;
            float             _BGIntensity;
            float             _CubeIntensity;
            float             _RefractionLevel;
            float             _RefractionIntensity;
            float             _HueShiftBG;
            float             _MatcapUVs;
            float             _ScaleBG;
            float             _ScaleMatcapBG;
            int               _RaymarchIterations;
            samplerCUBE       _SkyCube;
            float             _DopplerStrength;
            float             _PhotonRingIntensity;
            float             _PhotonRingWidth;
            float             _PhotonRingMatchDisk;

            // Structs
            struct appdata
            {
                float4 vertex  : POSITION;
                float2 uv      : TEXCOORD0;
                float4 tangent  : TANGENT;
                float3 normal  : NORMAL;
            };

            struct v2f
            {
                float4 pos      : SV_POSITION;
                float3 ro_o     : TEXCOORD3;
                float3 hitPos_o : TEXCOORD4;
                float3 wpos     : TEXCOORD0;
            };

            //  Utility functions

            // Remap [lowIn, lowIn+rangeIn] -> [0,1], optionally inverted.
            float fremap(float x, float lowIn, float rangeIn, bool invert)
            {
                float o = saturate(saturate(x - lowIn) / max(rangeIn, 0.0001));
                return invert ? 1.0 - o : o;
            }

            // Original space-distortion lerp factor: Rs^power / r^power
            float GetSpaceDistortionLerpValue(float Rs, float r, float power)
            {
                return pow(Rs, power) / pow(r, power);
            }

            float3 BlendOverlay(float3 base, float3 blend)
            {
                return base < 0.5
                    ? (2.0 * base * blend)
                    : (1.0 - 2.0 * (1.0 - base) * (1.0 - blend));
            }

            float spikes(float x)
            {
                x = 1.0 - abs(sin(x));
                return x * x;
            }

            float trapezoid(float x)
            {
                x = fract(x);
                if (x < 0.25) return 4.0 * x;
                if (x < 0.50) return 1.0;
                if (x < 0.75) return -4.0 * x + 3.0;
                return 0.0;
            }

            vec3 gradient(float y)
            {
                return trapezoid(y) * vec3(1.0, 0.0, 0.0)
                     + trapezoid(y - 0.25) * vec3(0.0, 1.0, 1.0);
            }

            vec3 hue01(float x)
            {
                x = mod(x, 6.0);
                return clamp(vec3(
                    abs(x - 3.0) - 1.0,
                   -abs(x - 2.0) + 2.0,
                   -abs(x - 4.0) + 2.0
                ), 0.0, 1.0);
            }

            vec3 deepfry(vec3 rgb, float x)
            {
                rgb *= x;
                return rgb + vec3(
                    max(0.0, rgb.g - 1.0) + max(0.0, rgb.b - 1.0),
                    max(0.0, rgb.b - 1.0) + max(0.0, rgb.r - 1.0),
                    max(0.0, rgb.r - 1.0) + max(0.0, rgb.g - 1.0));
            }

            vec3 fn01(vec2 polarCoord)
            {
                return deepfry(
                    hue01(polarCoord.x * 3.0 + iTime),
                    1.0 + 0.5 * sin(polarCoord.x * 6.0 + polarCoord.y * 3.0 + iTime * 4.0));
            }

            vec3 fn08(vec2 uv)
            {
                float time  = fract(iTime / 12.0);
                float dist  = log(uv.x * uv.x + uv.y * uv.y + 0.10) * 1.25;
                float angle = atan2(uv.y, uv.x);

                const float spokes  = 17.0 / 2.0;
                const float spokes2 = 55.0 / 2.0;

                float s1  = spikes(angle * spokes  - time * TAU);
                float s2  = spikes(angle * spokes2 + time * TAU);
                float und = sin(angle + time * TAU + 0.5 * dist);

                return gradient(
                    dist
                    + (0.3 + 0.1 * sin(2.0 * time * PI)) * s1
                    + (0.025 * (2.0 + sin(2.0 * time * PI + angle))) * s2
                    + 0.15 * und);
            }

            //  SDF primitives & operators

            float sdSphere(float3 pos, float radius)
            {
                return length(pos) - radius;
            }

            float sdRoundedCylinder(float3 pos, float ra, float rb, float h)
            {
                float2 d = float2(length(pos.xz) - 2.0 * ra + rb, abs(pos.y) - h);
                return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - rb;
            }

            float opSmoothSubtraction(float d1, float d2, float k)
            {
                float h = clamp(0.5 - 0.5 * (d2 + d1) / k, 0.0, 1.0);
                return lerp(d2, -d1, h) + k * h * (1.0 - h);
            }

            //  Hue-shift (YIQ)

            vec3 hue(vec3 color, float shift)
            {
                const vec3 kRGBToYPrime = vec3(0.299, 0.587, 0.114);
                const vec3 kRGBToI      = vec3(0.596, -0.275, -0.321);
                const vec3 kRGBToQ      = vec3(0.212, -0.523, 0.311);

                const vec3 kYIQToR = vec3(1.0,  0.956,  0.621);
                const vec3 kYIQToG = vec3(1.0, -0.272, -0.647);
                const vec3 kYIQToB = vec3(1.0, -1.107,  1.704);

                float YPrime = dot(color, kRGBToYPrime);
                float I      = dot(color, kRGBToI);
                float Q      = dot(color, kRGBToQ);

                float h      = atan2(Q, I);
                float chroma = sqrt(I * I + Q * Q);
                h += shift;

                Q = chroma * sin(h);
                I = chroma * cos(h);

                vec3 yIQ = vec3(YPrime, I, Q);
                color.r = dot(yIQ, kYIQToR);
                color.g = dot(yIQ, kYIQToG);
                color.b = dot(yIQ, kYIQToB);
                return color;
            }

            //  Noise

            float tri(float x) { return abs(fract(x) - 0.5); }

            float noise(vec3 x)
            {
                vec3 p = floor(x);
                vec3 f = fract(x);
                f = f * f * (3.0 - 2.0 * f);
                vec2 uv = (p.xy + vec2(37.0, 17.0) * p.z) + f.xy;
                vec2 rg = tex2D(_Noise, (uv + 0.5) / 256.0).yx;
                return -1.0 + 2.0 * lerp(rg.x, rg.y, f.z);
            }

            float map5(vec3 p)
            {
                vec3 q = p;
                float f;
                f  = 0.50000 * noise(q); q *= 2.02;
                f += 0.25000 * noise(q); q *= 2.03;
                f += 0.12500 * noise(q); q *= 2.01;
                f += 0.06250 * noise(q); q *= 2.02;
                f += 0.03125 * noise(q);
                return clamp(1.5 - p.y - 2.0 + 1.75 * f, 0.0, 1.0);
            }

            //  Coordinates

            void cartesianToSpherical(in vec3 xyz, out float rho, out float phi, out float theta)
            {
                rho   = length(xyz);
                phi   = asin(xyz.y / max(rho, 0.0001));
                theta = atan2(xyz.z, xyz.x);
            }

            //  Starfield

            vec3 hash33(vec3 p)
            {
                p  = fract(p * vec3(5.3983, 5.4427, 6.9371));
                p += dot(p.yzx, p.xyz + vec3(21.5351, 14.3137, 15.3219));
                return fract(vec3(p.x * p.z * 95.4337, p.x * p.y * 97.597, p.y * p.z * 93.8365));
            }

            vec3 stars(vec3 p)
            {
                float fov = radians(50.0);
                vec3 c = (vec3)0.0;
                float res = iResolution.x * 0.85 * fov;

                p.x += (tri(p.z * 50.0) + tri(p.y * 50.0)) * 0.006;
                p.y += (tri(p.z * 50.0) + tri(p.x * 50.0)) * 0.006;
                p.z += (tri(p.x * 50.0) + tri(p.y * 50.0)) * 0.006;

                for (float i = 0.0; i < 3.0; i++)
                {
                    vec3 q  = fract(p * (0.15 * res)) - 0.5;
                    vec3 id = floor(p * (0.15 * res));
                    float rn = hash33(id).z;
                    float c2 = 1.0 - smoothstep(-0.2, 0.4, length(q));
                    c2 *= step(rn, 0.005 + i * 0.014);
                    c += c2 * (lerp(vec3(1.0, 0.75, 0.5), vec3(0.85, 0.9, 1.0), rn * 30.0) * 0.5 + 0.5);
                    p *= 1.15;
                }
                return c * c * 1.5;
            }

            vec3 getCol(vec3 dir)
            {
                vec3 c0 = texCUBE(_SkyCube, dir).bgr;
                vec3 c1 = stars(dir);
                return c0 * _CubeIntensity + c1 * 2.0;
            }

            //  Accretion disk SDF

            float accretionDiskSDF(float3 p)
            {
                float scale = _AccretionDiskRadius / 6.0;
                float3 sp   = p / max(scale, 0.0001);

                float cyl    = sdRoundedCylinder(sp, 3.5, 0.25, 0.01);
                float sphere = sdSphere(sp, 3.5);

                return opSmoothSubtraction(sphere, cyl, 0.5) * scale;
            }

            //  Cloud colour & density

            void getCloudColorAndDensity(
                vec3 p, float time, float3 rayDir,
                out vec4 color, out float density, out vec2 diskPolar)
            {
                color     = 0;
                density   = 0;
                diskPolar = 0;

                float r = length(p);
                if (r < _SchwarzschildRadius)
                    return;

                float ringInner = max(_SchwarzschildRadius * 3.0,
                                      _SchwarzschildRadius + 0.8);
                float ringOuter = _AccretionDiskRadius;

                float rho, phi, theta;
                cartesianToSpherical(p, rho, phi, theta);

                float rhoNorm = (rho - ringInner) / max(ringOuter - ringInner, 0.0001);

                if (!IN_RANGE(p.y, -_AccretionDiskThickness, _AccretionDiskThickness) ||
                    !IN_RANGE(rhoNorm, 0.0, 1.0))
                    return;

                diskPolar = vec2(theta, rhoNorm);
                float cloudX = sqrt(rhoNorm);
                float cloudY = (p.y + _AccretionDiskThickness) / (2.0 * _AccretionDiskThickness);
                float cloudZ = theta / UNITY_TWO_PI;

                float blending = 1.0;
                blending *= lerp(rhoNorm * 5.0,
                                 1.0 - (rhoNorm - 0.2) / max(0.8 * rhoNorm, 0.0001),
                                 rhoNorm > 0.2);
                blending *= lerp(cloudY * 2.0,
                                 1.0 - (cloudY - 0.5) * 2.0,
                                 cloudY > 0.5);

                vec3 moving     = vec3(time * 0.5, 0.0, time * rhoNorm * 0.01);
                vec3 localCoord = vec3(cloudX * (rhoNorm * rhoNorm), -0.05 * cloudY, cloudZ);

                density = blending * map5((localCoord + moving) * 100.0);

                // Doppler beaming
                float3 tangent = normalize(float3(-p.z, 0.0, p.x));
                float orbitalSpeed = sqrt(_SchwarzschildRadius / max(2.0 * rho, 0.001));
                float doppler = 1.0 + _DopplerStrength
                              * dot(tangent, normalize(rayDir)) * orbitalSpeed;
                doppler = max(doppler, 0.1);

                vec4 innerCol = vec4(_AccretionDiskColor.rgb, rhoNorm * density);
                vec4 outerCol = vec4(hue(_AccretionDiskColor.rgb, _AccretionDiskColor.a),
                                     rhoNorm * density);
                color = 5.0 * lerp(innerCol, outerCol, rhoNorm) * doppler;
            }

            //  Normal

            float3 getNormal(float3 pos)
            {
                float2 e = float2(1.0, -1.0) * 0.5773 * 0.001;
                return normalize(
                    e.xyy * accretionDiskSDF(pos + e.xyy) +
                    e.yyx * accretionDiskSDF(pos + e.yyx) +
                    e.yxy * accretionDiskSDF(pos + e.yxy) +
                    e.xxx * accretionDiskSDF(pos + e.xxx));
            }

            //  Main raymarch
            //
            //  Hybrid lensing:
            //    Close to the hole  — original's lerp between "go straight"
            //      and "go toward singularity" for smooth artistic control.
            //    Far from the hole  — physically-based deflection force
            //      (1.5 Rs²/r³) for correct Einstein-ring behavior.
            //    Smooth blend between the two across [2 Rs .. 5 Rs].
            //
            //  Black-hole influence:
            //    Restored the original's per-step fremap with _HoleThickness
            //    for a soft continuous gradient between sky and _BlackHoleColor.

            float4 raymarch(float3 ro, float3 rd)
            {
                int   maxstep  = _RaymarchIterations;
                float epsilon  = _Epsilon;
                float stepSize = _StepSize;

                float3 pos            = ro;
                float3 vel            = normalize(rd) * stepSize;
                float3 bhPos          = _Offset;
                float  distToSing     = 1e8;
                float  blackHoleInfluence = 0.0;
                float  closestApproach = 1e8;

                // Front-to-back volumetric compositing
                float3 lightAccum = float3(0, 0, 0);
                float  alphaAccum = 1.0;

                // Psychedelic pulse — computed once per ray from the initial
                // view direction for sharp screen-space streaks.
                float3 diskPulse = fn01(rd.xz * _AcrretionDiskPulses)
                                 * tex2D(_Noise, rd.xz * _Noise_ST.xy + _Noise_ST.zw).rgb;

                // Jitter ray start to break step-aliasing bands.
                float jitter = frac(sin(dot(rd.xy, float2(12.9898, 78.233))) * 43758.5453);
                pos += vel * jitter;

                [loop]
                for (int i = 0; i < maxstep; ++i)
                {
                    // ---- Hybrid gravitational lensing ----
                    float3 toBH = bhPos - pos;
                    distToSing  = length(toBH);
                    float3 n    = toBH / max(distToSing, 0.0001);

                    closestApproach = min(closestApproach, distToSing);

                    // Event horizon — ray absorbed
                    if (distToSing < _SchwarzschildRadius)
                        break;

                    // Method A: Original artistic lerp
                    //   Interpolates between "keep going straight" and
                    //   "aim at singularity" based on Rs^power / r^power.
                    //   Gives smooth, artist-controllable near-field pull.
                    float3 straightDir = normalize(vel) * stepSize;
                    float3 captureDir  = n * stepSize;
                    float  lerpValue   = GetSpaceDistortionLerpValue(
                                             _SchwarzschildRadius,
                                             distToSing,
                                             _SpaceDistortion);
                    float3 lerpDir = normalize(lerp(straightDir, captureDir, lerpValue)) * stepSize;

                    // Method B: Physical deflection force
                    //   Acceleration = 1.5 Rs²/r³ toward BH, then re-normalise.
                    //   Produces correct Einstein rings and photon-sphere orbits.
                    float  deflection = 1.5 * _SchwarzschildRadius * _SchwarzschildRadius
                                      / (distToSing * distToSing * distToSing);
                    float3 physDir = normalize(vel + n * deflection * stepSize) * stepSize;

                    // Blend: lerp dominates close to the hole (< 2 Rs),
                    // physics takes over far out (> 5 Rs).
                    float physBlend = smoothstep(_SchwarzschildRadius * 2.0,
                                                _SchwarzschildRadius * 5.0,
                                                distToSing);
                    vel = lerp(lerpDir, physDir, physBlend);

                    float3 newPos = pos + vel;

                    // ---- Accretion-disk sampling ----
                    float sdfResult    = accretionDiskSDF(newPos);
                    float softEdge     = stepSize * 3.0;
                    float volumeWeight = smoothstep(softEdge, -softEdge, sdfResult);

                    if (volumeWeight > 0.001)
                    {
                        // Psychedelic pulse — constant per-ray, every step
                        lightAccum += alphaAccum * diskPulse * volumeWeight;

                        // Cloud emission — density-gated
                        float4 col;
                        float  density;
                        vec2   diskPolar;
                        getCloudColorAndDensity(newPos, iTime * 0.25, vel,
                                                col, density, diskPolar);

                        if (density > 0.0)
                        {
                            float3 cloudEmission = col.rgb * density
                                                 * _AccretionDiskIntensity
                                                 * volumeWeight;

                            float absorb = saturate(density * stepSize * 8.0
                                                    * volumeWeight);
                            lightAccum  += alphaAccum * cloudEmission;
                            alphaAccum  *= (1.0 - absorb);
                        }
                    }

                    // Black-hole influence — updated every step, but the
                    // LAST step's value is what matters for the post-loop
                    // sky/BH blend, exactly like the original.
                    blackHoleInfluence = fremap(distToSing, _SchwarzschildRadius,
                                               _HoleThickness, true);

                    pos = newPos;

                    if (alphaAccum < 0.01)
                        break;
                }

                // ---- Post-loop compositing ----

                float3 lensedDir = normalize(vel);

                // Skybox + stars along lensed direction
                float3 skyStars = getCol(lensedDir);
                skyStars = pow(skyStars, 2.2);

                // Psychedelic background pattern in lensed coords
                float3 worldNormal = getNormal(pos + vel);
                float2 matcapUV    = 0.5 + _ScaleMatcapBG
                                   * mul((float3x3)UNITY_MATRIX_V, worldNormal).xy;

                float2 patternUV;
                UNITY_BRANCH
                if (_MatcapUVs)
                    patternUV = matcapUV * _ScaleBG;
                else
                    patternUV = lensedDir.xy * _ScaleBG;

                float3 skyColor   = fn08(patternUV);
                float3 blendColor = BlendOverlay(
                    clamp(tex2D(_GrabdTexture, matcapUV * _RefractionLevel)
                          * _RefractionIntensity, 0.0, 1.0),
                    hue(skyColor * _BGIntensity, _HueShiftBG));

                blendColor = pow(blendColor, 2.2);

                // Photon-sphere glow
                float photonRadius = 1.5 * _SchwarzschildRadius;
                float ringDist     = abs(closestApproach - photonRadius);
                float sigma2       = _PhotonRingWidth * _PhotonRingWidth
                                   * _SchwarzschildRadius * _SchwarzschildRadius;
                float photonGlow   = _PhotonRingIntensity
                                   * exp(-ringDist * ringDist / max(sigma2, 0.0001));

                float3 photonColor;
                UNITY_BRANCH
                if (_PhotonRingMatchDisk)
                {
                    float pTheta = atan2(lensedDir.z, lensedDir.x);
                    vec2  ringPolar = vec2(pTheta, 0.5) * _AcrretionDiskPulses;
                    vec3  ringPattern = fn01(ringPolar);
                    photonColor = ringPattern * _AccretionDiskColor.rgb;
                }
                else
                {
                    photonColor = lerp(float3(0.8, 0.9, 1.0),
                                       _AccretionDiskColor.rgb, 0.3);
                }

                // Sky + refraction + photon ring
                float3 skyComposite = skyStars + blendColor;
                skyComposite += photonGlow * photonColor;

                // Blend sky toward _BlackHoleColor using the soft gradient.
                // blackHoleInfluence is 0 far away, 1 at the event horizon,
                // with a smooth ramp controlled by _HoleThickness.
                float4 background = lerp(float4(skyComposite, 0.0),
                                         _BlackHoleColor,
                                         blackHoleInfluence);

                // Volumetric disk + remaining transmittance * background
                float3 finalColor = lightAccum + alphaAccum * background.rgb;

                return float4(finalColor, 1.0);
            }

            //  Vertex / Fragment

            v2f vert(appdata v)
            {
                v2f o;
                o.pos      = UnityObjectToClipPos(v.vertex);
                o.wpos     = mul(unity_ObjectToWorld, float4(0, 0, 0, 1)).xyz;
                o.ro_o     = _WorldSpaceCameraPos.xyz - o.wpos;
                o.hitPos_o = mul(unity_ObjectToWorld, v.vertex).xyz - o.wpos;
                return o;
            }

            float4 frag(v2f i, float facing : VFACE) : SV_Target
            {
                float3 ro = i.ro_o;
                float3 rd = normalize(i.hitPos_o - i.ro_o);
                if (facing > 0)
                    ro = i.hitPos_o;

                return saturate(raymarch(ro, rd));
            }

            ENDCG
        }
    }
}
