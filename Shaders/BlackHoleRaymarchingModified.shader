// Created by Johan Svensson. https://medium.com/dotcrossdot
// Raymarching setup based on http://flafla2.github.io/2016/10/01/raymarching.html.
// The raymarching algorithm is changed to have a fixed step distance for volumetric sampling
// and create a light bending black hole with an accretion disk around it. 

Shader "DotCrossDot/BlackHoleRaymarchingModified"
{
	Properties
	{
		[HDR]_BlackHoleColor ("Black hole color", Color) = (0,0,0,1)
		_SchwarzschildRadius ("schwarzschildRadius", Float) = 0.5
		_SpaceDistortion ("Space distortion", Float) = 4.069
		_AccretionDiskColor("Accretion disk color (alpha hueshift)", Color) = (1,1,1,1)
		_AccretionDiskThickness("Accretion disk thickness", Float) = 1
		_Noise("Accretion disk noise", 2D) = "" {}
		_Epsilon ("Epsilon", Float) = 0.01
		_StepSize ("Step Size", Range(0,2)) = 0.05
        _Offset("Center Offset", Vector) = (0, 0, 0)
		_HoleThickness ("Hole Thickness", Range(0,1)) = 0.01
		_AcrretionDiskPulses ("Accretion Disk Pulses", Range(0,5)) = 2.50
		[PowerSlider(5.0)]_BGIntensity ("Background Intensity", Range(0,10)) = 0.4
		[PowerSlider(5.0)]_ReflectionIntensity ("Reflection Intensity", Range(0,10)) = 1.00
		_HueShiftBG ("Hue Shift Background", Range(0,7)) = 1.00
		_AcrretionDiskPulses ("Accretion Disk Pulses", Range(0,15)) = 2.50
		_SpaceDistortion ("Space distortion", Float) = 4.069
		_Epsilon ("Epsilon", Float) = 0.01
		[PowerSlider(5.0)]_ScaleBG ("ScaleBG", Range(0,20)) = 1.00
        [Toggle] _MatcapUVs("Toggle Matcap Mode", Float) = 1
		[PowerSlider(5.0)]_ScaleMatcapBG ("ScaleMatcapBG", Range(0,20)) = 1.00


	}
	SubShader
	{
		Tags { "RenderType" = "Transparent" "Queue" = "Transparent" }
		GrabPass { "_GrabTexture" }
		Pass {
			Zwrite On
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
			#include "UnityCG.cginc"
			#include "SDFMaster.cginc"
			#define iTime _Time.y
			#define mod(x,y) (x-y*floor(x/y)) // glsl mod			
			#define IN_RANGE(x,a,b)		(((x) > (a)) && ((x) < (b)))

			
			// Set from material.
			uniform sampler2D _Noise;
			float _SpaceDistortion;
			float _SchwarzschildRadius;
			float4 _AccretionDiskColor;
			float4 _BlackHoleColor;
			float _AccretionDiskThickness;
            sampler2D _GrabTexture;
			float _Epsilon;
			float _StepSize;
            float3 _Offset;
			float _HoleThickness;
			float _AcrretionDiskPulses;
			float _BGIntensity;
			float _ReflectionIntensity;
			float _HueShiftBG;
			float _MatcapUVs;
			float _ScaleBG;
			float _ScaleMatcapBG;

	
			struct vi {
				float4 vertex: POSITION;
				float2 uv: TEXCOORD0;
				float4 tangent: TANGENT;
				float3 normal: NORMAL;
			};

			struct vo {
				float4 pos : SV_POSITION;
				float3 ro_o : TEXCOORD3;
				float3 hitPos_o : TEXCOORD4;
				float3 wpos : TEXCOORD0;
				
			};
			float tri(in float x){return abs(fract(x)-.5);}

			float noise( in vec3 x ) {
				vec3 p = floor(x);
				vec3 f = fract(x);
				f = f*f*(3.0-2.0*f);
				vec2 uv = ( p.xy + vec2(37.0,17.0)*p.z ) + f.xy;
				vec2 rg = tex2D( _Noise, (uv+ 0.5)/256.0).yx;
				return -1.0+2.0*mix( rg.x, rg.y, f.z );
			}
			
			float map5( in vec3 p ) {
				vec3 q = p;
				float f;
				f  = 0.50000*noise( q ); q = q*2.02;
				f += 0.25000*noise( q ); q = q*2.03;
				f += 0.12500*noise( q ); q = q*2.01;
				f += 0.06250*noise( q ); q = q*2.02;
				f += 0.03125*noise( q );
				return clamp( 1.5 - p.y - 2.0 + 1.75*f, 0.0, 1.0 );
			}

			void cartesianToSpherical( 	in vec3 xyz,
										out float rho,
										out float phi,
										out float theta ) {
				rho = sqrt((xyz.x * xyz.x) + (xyz.y * xyz.y) + (xyz.z * xyz.z));
				phi = asin(xyz.y / rho);
				theta = atan( xyz.z, xyz.x );
			}
			vec3 hash33(vec3 p){
				p  = fract(p * vec3(5.3983, 5.4427, 6.9371));
				p += dot(p.yzx, p.xyz  + vec3(21.5351, 14.3137, 15.3219));
				return fract(vec3(p.x * p.z * 95.4337, p.x * p.y * 97.597, p.y * p.z * 93.8365));
			}
			vec3 hue(vec3 color, float shift) {

				const vec3  kRGBToYPrime = vec3 (0.299, 0.587, 0.114);
				const vec3  kRGBToI     = vec3 (0.596, -0.275, -0.321);
				const vec3  kRGBToQ     = vec3 (0.212, -0.523, 0.311);

				const vec3  kYIQToR   = vec3 (1.0, 0.956, 0.621);
				const vec3  kYIQToG   = vec3 (1.0, -0.272, -0.647);
				const vec3  kYIQToB   = vec3 (1.0, -1.107, 1.704);

				// Convert to YIQ
				float   YPrime  = dot (color, kRGBToYPrime);
				float   I      = dot (color, kRGBToI);
				float   Q      = dot (color, kRGBToQ);

				// Calculate the hue and chroma
				float   hue     = atan (Q, I);
				float   chroma  = sqrt (I * I + Q * Q);

				// Make the user's adjustments
				hue += shift;

				// Convert back to YIQ
				Q = chroma * sin (hue);
				I = chroma * cos (hue);

				// Convert back to RGB
				vec3    yIQ   = vec3 (YPrime, I, Q);
				color.r = dot (yIQ, kYIQToR);
				color.g = dot (yIQ, kYIQToG);
				color.b = dot (yIQ, kYIQToB);

				return color;
			}

			//smooth and cheap 3d starfield
			vec3 stars(in vec3 p)
			{
				float fov = radians(50.0);
				vec3 c = (vec3)(0.);
				float res = iResolution.x*.85*fov;
				
				//Triangular deformation (used to break sphere intersection pattterns)
				p.x += (tri(p.z*50.)+tri(p.y*50.))*0.006;
				p.y += (tri(p.z*50.)+tri(p.x*50.))*0.006;
				p.z += (tri(p.x*50.)+tri(p.y*50.))*0.006;
				
				for (float i=0.;i<3.;i++)
				{
					vec3 q = fract(p*(.15*res))-0.5;
					vec3 id = floor(p*(.15*res));
					float rn = hash33(id).z;
					float c2 = 1.-smoothstep(-0.2,.4,length(q));
					c2 *= step(rn,0.005+i*0.014);
					c += c2*(mix(vec3(1.0,0.75,0.5),vec3(0.85,0.9,1.),rn*30.)*0.5 + 0.5);
					p *= 1.15;
				}
				return c*c*1.5;
			}			
			vec3 getCol( vec3 dir , float2 uvs) {
				float rho, phi, theta;
				vec3 c0 = tex2D( _GrabTexture, uvs).xyz*0.83;
				vec3 c1 = stars(dir);
				return c0.bgr*_ReflectionIntensity + c1*2.0;
			}

			void getCloudColorAndDencity(vec3 p, float time, out vec4 color, out float dencity ) {
				float d2 = dot(p,p);
				float3 gargantua_position_ = vec3(0.0, 0.0, 0.0 );
				float gargantua_ring_radius_inner_ = _SchwarzschildRadius+ 0.8;
				float gargantua_ring_radius_outer_ = 6.0;
				if( sqrt(d2) < _SchwarzschildRadius) {
					dencity = 0.0;
				} else {
					float rho, phi, theta;
					cartesianToSpherical( p, rho, phi, theta );
					rho = ( rho - gargantua_ring_radius_inner_)/(gargantua_ring_radius_outer_ - gargantua_ring_radius_inner_);

					if( !IN_RANGE( p.y, -_AccretionDiskThickness, _AccretionDiskThickness ) ||
						!IN_RANGE( rho, 0.0, 1.0 ) ) {
						dencity = 0.0;
					} else {
						float cloudX = sqrt( rho );
						float cloudY = ((p.y - gargantua_position_.y) + _AccretionDiskThickness ) / (2.0*_AccretionDiskThickness);
						float cloudZ = (theta/UNITY_TWO_PI);

						float blending = 1.0; 

						blending *= mix(rho*5.0, 1.0 - (rho-0.2)/(0.8*rho), rho>0.2);
						blending *= mix(cloudY*2.0, 1.0 -(cloudY-0.5)*2.0, cloudY > 0.5);

						vec3 moving = vec3( time*0.5, 0.0, time*rho*0.01 );

						vec3 localCoord = vec3( cloudX*(rho*rho), -0.05*cloudY, cloudZ );

						dencity = blending*map5( (localCoord + moving)*100.0 );
						color = 5.0*mix( vec4( _AccretionDiskColor.rgb, rho*dencity ), vec4( hue(_AccretionDiskColor.rgb, _AccretionDiskColor.a), rho*dencity ), rho );
					}
				}
			}

			// A SDF combination creating something that looks like an accretion disk.
			// Made up of a flattened rounded cylinder from which we subtract a sphere.
			float accretionDiskSDF(float3 p) {
				float p1 = sdRoundedCylinder(p, 3.5, 0.25, 0.01);
				float p2 = sdSphere(p, 3.5);
				return opSmoothSubtraction(p2, p1, 0.5);
			}

			// An (very rough!!) approximation of how light is bent given the distance to a black hole. 
			float GetSpaceDistortionLerpValue(float schwarzschildRadius, float distanceToSingularity, float spaceDistortion) {
				return pow(schwarzschildRadius, spaceDistortion) / pow(distanceToSingularity, spaceDistortion);
			}
			float3 getNormal(float3 pos)
			{
				float2 e = float2(1.0, -1.0) * 0.5773 * 0.001;
				return normalize (
					e.xyy * accretionDiskSDF(pos + e.xyy) +
					e.yyx * accretionDiskSDF(pos + e.yyx) +
					e.yxy * accretionDiskSDF(pos + e.yxy) +
					e.xxx * accretionDiskSDF(pos + e.xxx));
			}

			float4 raymarch(float3 ro, float3 rd) {
				float4 ret = _AccretionDiskColor;
				ret.a = 0;

				const int maxstep = 162;
				float3 previousPos = ro;
				float epsilon = _Epsilon;
				float stepSize = _StepSize;
				float thickness = 0;
				float3 previousRayDir = rd;
				float3 blackHolePosition = _Offset;
				float distanceToSingularity = 99999999;
				float blackHoleInfluence = 0;
				float4 lightAccumulation = float4(0, 0, 0, 1);
				float3 newPos = float3(0,0,0);
				float4 col = float4(0,0,0,0);
				float3 skyColor2 = fn01(rd.xz * _AcrretionDiskPulses);
				
				for (int i = 0; i < maxstep; ++i) {
					// Get two vectors. One pointing in previous direction and one pointing to the singularity. 
					float3 unaffectedDir = normalize(previousRayDir) * stepSize;
					float3 maxAffectedDir = normalize(blackHolePosition - previousPos) * stepSize;
					distanceToSingularity = distance(blackHolePosition, previousPos);

					// Calculate how to interpolate between the two previously calculated vectors.
					float lerpValue = GetSpaceDistortionLerpValue(_SchwarzschildRadius, distanceToSingularity, _SpaceDistortion);
					float3 newRayDir = normalize(lerp(unaffectedDir, maxAffectedDir, lerpValue)) * stepSize;

					// Move the lightray along and calculate the sdf result
					newPos = previousPos + newRayDir;
					float sdfResult = accretionDiskSDF(newPos);

					// Inside the acceration disk. Sample light.
					if (sdfResult < epsilon) {
						getCloudColorAndDencity(newPos, iTime*0.25, col, thickness);
						// Add to the rays light accumulation.
						lightAccumulation += float4(skyColor2,0.0) * col * log(exp(thickness * distanceToSingularity));
					}

					// Calculate black hole influence on the final color.
					blackHoleInfluence = fremap(distanceToSingularity, _SchwarzschildRadius, _HoleThickness, true);
					previousPos = newPos;
					previousRayDir = newRayDir;

				}
				// Sample the skybox.+
				float3 worldNormal = getNormal(ro + distanceToSingularity * previousRayDir);
				float3 col3 = float3(0.,0.,0.);
				float3 skyColor = float3(0.,0.,0.);
				UNITY_BRANCH
				float2 matcapUV = _ScaleMatcapBG + 0.5 * mul((float3x3)UNITY_MATRIX_V, worldNormal).xy;
				col3 = getCol(ro + distanceToSingularity * previousRayDir, matcapUV);
				if(_MatcapUVs) {
					skyColor = fn08(matcapUV * _ScaleBG);
				} else {
					skyColor = fn08(rd.xy * _ScaleBG);					
				}
				float4 backGround = float4(.0,.0,.0,.0);
				// Sample let background be either skybox or the black hole color.
				backGround = lerp(float4(BlendOverlay(col3, hue(skyColor * _BGIntensity,_HueShiftBG)), 0), _BlackHoleColor, blackHoleInfluence);
				// Return background and light.
				return backGround + lightAccumulation;
			}



			vo vert(vi v)
			{
				vo o;
				o.pos = UnityObjectToClipPos (v.vertex);
                o.wpos = mul(unity_ObjectToWorld, float4(0, 0, 0, 1));
				o.ro_o = _WorldSpaceCameraPos.xyz -  o.wpos;
				o.hitPos_o = mul(unity_ObjectToWorld, v.vertex).xyz -  o.wpos;

				return o;
			}
			
			float4 frag(vo i, float facing : VFACE) : SV_Target
			{
				float3 ro = i.ro_o;
				float3 rd = normalize(i.hitPos_o - i.ro_o);
				if (facing > 0) {
					ro = i.hitPos_o;
				}
				float4 col = raymarch(ro, rd);
				col = clamp(col, 0.0, 1.0);
				return col;
			}
			ENDCG
		}
	}
}