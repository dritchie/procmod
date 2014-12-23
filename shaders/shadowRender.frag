
uniform sampler2D shadowMap;
varying vec4 shadowPos;
varying vec3 normal;
varying vec3 light;

void main()
{
	// Avoid shadow acne
	float bias = 0.005*tan(acos(dot(normal,light)));
	bias = clamp(bias, 0.0, 0.01);
	// Homogenous coordinates are [-1,1], but texture sampling expects [0,1]
	vec2 shadowTexCoord = 0.5*(shadowPos.xy + vec2(1.0));

	float shadow = 0.0;

	// float depth = shadowPos.z;
	float depth = 0.5*(shadowPos.z + 1.0);

	float storedDepth = texture2D(shadowMap, shadowTexCoord).x;

	if (storedDepth < depth - bias)
	{
		shadow = 1.0;
	}

	gl_FragColor = vec4(shadow, shadow, shadow, 1.0);
}