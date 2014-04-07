#include <optix.h>
#include <optixu/optixu_math_namespace.h>
#include "helpers.h"
#include "common_structs.h"
#include "random.h"

using namespace optix;

// use offline rendering

// rtDeclareVariable(unsigned int, thread_index, attribute thread_index, );
rtDeclareVariable(uint2, thread_index, rtLaunchIndex, );
rtDeclareVariable(uint2, thread_dim, rtLaunchDim, );

rtDeclareVariable(rtObject, top_object, , );
rtDeclareVariable(rtObject, top_shadower, , );
rtDeclareVariable(float, scene_epsilon, , );
rtDeclareVariable(int, max_depth, , );
rtDeclareVariable(unsigned int, radiance_ray_type, , );
rtDeclareVariable(unsigned int, shadow_ray_type, , );
rtDeclareVariable(float3, shading_normal, attribute shading_normal, );
rtDeclareVariable(float3, tangent, attribute tangent, ); 
rtDeclareVariable(float3, bitangent, attribute bitangent, ); 
rtDeclareVariable(float3, front_hit_point, attribute front_hit_point, );
rtDeclareVariable(float3, back_hit_point, attribute back_hit_point, );

rtDeclareVariable(Ray, ray, rtCurrentRay, );
rtDeclareVariable(float, isect_dist, rtIntersectionDistance, );

rtDeclareVariable(float3, ambient_light_color, , );

rtDeclareVariable(int, is_emissive, , );

rtDeclareVariable(float3, k_emission, , );
rtDeclareVariable(float3, k_ambient, , );
rtDeclareVariable(float3, k_diffuse, , );
rtDeclareVariable(float3, k_specular, , );
rtDeclareVariable(float3, k_reflective, , );
rtDeclareVariable(float3, k_refractive, , );
rtDeclareVariable(int, ns, , );
rtDeclareVariable(float, glossiness, , );

rtDeclareVariable(float3, texcoord, attribute texcoord, ); 
rtDeclareVariable(float3, cutoff_color, , );
rtDeclareVariable(int, reflection_maxdepth, , ) = 5;
rtDeclareVariable(int, refraction_maxdepth, , ) = 5;
rtDeclareVariable(float, importance_cutoff, , );
rtDeclareVariable(float, IOR, , ) = 1.3;

rtDeclareVariable(int, has_diffuse_map, , );
rtDeclareVariable(int, has_normal_map, , );
rtDeclareVariable(int, has_specular_map, , );

rtTextureSampler<float4, 2> kd_map;
rtTextureSampler<float4, 2> ks_map;
rtTextureSampler<float4, 2> normal_map;

rtDeclareVariable(int, soft_shadow_on, ,) = false;
rtDeclareVariable(int, glossy_on, ,) = false;
rtDeclareVariable(int, gi_on, ,) = false;

rtDeclareVariable(unsigned int, frame_number, , );

// rtBuffer<BasicLight> lights;
rtBuffer<RectangleLight> area_lights;

struct PerRayData_radiance
{
	float3 result;
	float importance;
	int depth;
};

struct PerRayData_shadow
{
	float3 attenuation;
};

rtDeclareVariable(PerRayData_radiance, prd_radiance, rtPayload, );
rtDeclareVariable(PerRayData_shadow, prd_shadow, rtPayload, );

#define PI 3.1415926

static __device__ __inline__ bool float_vec_length(float3 v) {
	return sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
}

static __device__ __inline__ bool floatVecZero(float3 v) {
	return v.x < scene_epsilon && v.y < scene_epsilon && v.z < scene_epsilon;
}

/*	calculate fresnel reflection */
static __device__ __inline__ float3 schlick(float nDi, const float3& rgb) {
	float r = fresnel_schlick(nDi, 5, rgb.x, 1);
	float g = fresnel_schlick(nDi, 5, rgb.y, 1);
	float b = fresnel_schlick(nDi, 5, rgb.z, 1);
	return make_float3(r, g, b);
}

static __device__ __inline__ float float3_sum(float3 v) {
	return v.x + v.y + v.z;
}

/*  randomize a vector based on normal distribution, used for 
    normal vectors in glossy reflection and refraction */
static __device__ float3 randomize_vector(const float3& v, float amount, unsigned int& seed) {
	// two random number for normal distribution
	float rand1 = rnd(seed), rand2 = rnd(seed);

	// X and Y are normally distributed random numbers
	float X = sqrt(- 2 * log(rand1)) * cos(2 * PI * rand2) * amount / 5;
	float Y = sqrt(- 2 * log(rand1)) * sin(2 * PI * rand2) * amount / 5;

	// make a vector not parallel to v to find v's tangent and bitangent
	float3 u = v;
	u.x += 1;

	// tangent
	float3 e1 = cross(u, v);

	//bitangent
	float3 e2 = cross(v, e1);

	normalize(e1);
	normalize(e2);

	// randomize v in its tangent and bitangent direction
	float3 rand_vec = v + e1 * X + e2 * Y;
	normalize(rand_vec);

	return rand_vec;
}

static __device__ __inline__ void createONB( const optix::float3& n, optix::float3& U, optix::float3& V) {
	U = cross( n, make_float3( 0.0f, 1.0f, 0.0f ) );
	if ( dot(U, U) < 1.e-3f ) {
		U = cross( n, make_float3( 1.0f, 0.0f, 0.0f ) );
	}
	U = normalize( U );
	V = cross( n, U );
}

static __device__ __inline__ float3 TraceRay(float3 origin, float3 direction, int depth, float importance )
{
	optix::Ray ray = optix::make_Ray( origin, direction, radiance_ray_type, 0.0f, RT_DEFAULT_MAX );
	PerRayData_radiance prd;
	prd.depth = depth;
	prd.importance = importance;

	rtTrace( top_object, ray, prd );
	return prd.result;
}

RT_PROGRAM void any_hit_shadow()
{
	if (!is_emissive) {
		prd_shadow.attenuation = make_float3(0.0f);
		rtTerminateRay();
	}
}

RT_PROGRAM void closest_hit_radiance()
{
	if (is_emissive) { // emissive object, just return the light color
		prd_radiance.result = k_emission;
		return;
	}

	if (prd_radiance.depth > max_depth || prd_radiance.importance < importance_cutoff) {
		prd_radiance.result = make_float3(0);
		return;
	}

	// seed used for random number generation
	unsigned int seed = tea<16>(thread_index.y * thread_dim.x + thread_index.x, thread_index.y + frame_number);

	const float3 ray_dir = ray.direction; 
	const float3 uvw = texcoord;

	float3 kd;
	if (has_diffuse_map) { // has diffuse map, sample the texture
		kd = make_float3( tex2D( kd_map, uvw.x, uvw.y ) );
	} else {
		kd = k_diffuse;
	}

	float3 ks;
	if (has_specular_map) { // has specular map, sample the texture
		ks = make_float3( tex2D( ks_map, uvw.x, uvw.y ) );
	} else {
		ks = k_specular;
	}

	// Here tangent, bitangent and normal are attribute variables set in the ray-generation program,
	// transform them to the work space using the normal transformation matrix
	const float3 T = normalize(rtTransformNormal(RT_OBJECT_TO_WORLD, tangent)); // tangent	
	const float3 B = normalize(rtTransformNormal(RT_OBJECT_TO_WORLD, bitangent)); // bitangent	
	const float3 N = normalize(rtTransformNormal(RT_OBJECT_TO_WORLD, shading_normal)); // normal	

	// normal vector after considering normal map (if any)
	float3 normal;

	if (has_normal_map) { // has normal map, sample the texture
		const float3 k_normal = make_float3( tex2D( normal_map, uvw.x, uvw.y) );
		const float3 coeff = k_normal * 2 - make_float3(1, 1, 1); // transform from RGB to normal
		normal = T * coeff.x + B * coeff.y + N * coeff.z;
	} else {
		normal = N;
	}

	// first hit point
	const float3 fhp = rtTransformPoint(RT_OBJECT_TO_WORLD, front_hit_point);

	const int depth = prd_radiance.depth;

	// starting from the ambient color
	float3 result = kd * ambient_light_color;
		
	for (int i = 0; i < area_lights.size(); i++) {
		RectangleLight light = area_lights[i];

		// according to whether offline rendering is activated, use different number of samples to
		// achieve soft or hard shadow
		const int numShadowSamples = soft_shadow_on ? 30 : 1;

		for (int j = 0; j < numShadowSamples; j++) {
			float3 sampledPos;
			if (soft_shadow_on) {
				sampledPos = light.pos + rnd(seed) * light.r1 + rnd(seed) * light.r2;
			} else {
				sampledPos = light.pos + 0.5 * light.r1 + 0.5 * light.r2;
			}

			float Ldist = length(sampledPos - fhp);

			float3 L = normalize(sampledPos - fhp);
			float3 H = normalize(L - ray.direction);

			float nDl = dot(normal, L);

			// cast shadow ray
			PerRayData_shadow shadow_prd;
			shadow_prd.attenuation = make_float3(1);

			if(nDl > 0) {
				optix::Ray shadow_ray = optix::make_Ray( fhp, L, shadow_ray_type, scene_epsilon, Ldist );
				rtTrace(top_shadower, shadow_ray, shadow_prd);
				result += light.color * shadow_prd.attenuation 
					* (kd * nDl + ks * max(pow(dot(H, normal), ns), .0f)) / numShadowSamples;
			}
		}
	}

	/* global illunimation */
	if (gi_on) {
		float3 p;
		cosine_sample_hemisphere(rnd(seed), rnd(seed), p);
		float3 v1, v2;
		createONB(normal, v1, v2);

		float3 random_ray_direction = v1 * p.x + v2 * p.y + normal * p.z;

		int depth = prd_radiance.depth + 1;
		if (depth <= max_depth) {
			float3 random_ray_color = TraceRay(fhp, random_ray_direction, depth,
				prd_radiance.importance) * kd;

			result += random_ray_color;
		}
	}

	/* reflection */
	if (!floatVecZero(k_reflective) && depth < min(reflection_maxdepth, max_depth)) {
		float3 refl_color = make_float3(0, 0, 0);

		// reflection direction
		const float3 refl = reflect(ray_dir, normal);
		const float3 fresnel = schlick(- dot(normal, ray_dir), k_reflective);
		float importance = prd_radiance.importance * optix::luminance(fresnel);

		// number of samples to take for each reflection
		if (glossy_on) {
			const int numGlossySample = 30;
			
			if (importance > importance_cutoff) {
				for (int i = 0; i < numGlossySample; i++) {
					float3 randomizedRefl = randomize_vector(refl, glossiness, seed);
					refl_color += TraceRay(fhp, randomizedRefl, depth + 1, importance / float(numGlossySample))
						/ numGlossySample;
				}
			}
		} else {
			refl_color = TraceRay(fhp, refl, depth + 1, importance);
		}
		result += k_reflective * refl_color;
	}

	/* refraction */
	if (!floatVecZero(k_refractive) && depth < min(refraction_maxdepth, max_depth)) {
		float3 refr_color = make_float3(0, 0, 0);

		float3 transmission_direction;
		if (refract(transmission_direction, ray_dir, normal, IOR)) {
			// check whether it is internal or external refraction
			float cos_theta = dot(ray_dir, normal);
			if (cos_theta < 0) { // external
				cos_theta = - cos_theta;
			} else { // internal
				cos_theta = dot(transmission_direction, normal);
			}

			refr_color = TraceRay(fhp, transmission_direction, depth + 1, prd_radiance.importance) * k_refractive;

			/*
			float importance = prd_radiance.importance * (1 - reflection) * optix::luminance(k_reflective * beer_attenuation);
			if (importance > importance_cutoff) {
				// refr_color = TraceRay(fhp, transmission_direction, depth + 1, importance);
			}
			*/
		}
		result += refr_color;
	}
	
	prd_radiance.result = result;
}

