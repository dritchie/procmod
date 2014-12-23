
uniform mat4 shadowMVP;
uniform vec3 lightDir;
varying vec4 shadowPos;
varying vec3 normal;
varying vec3 light;

void main()
{
	gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;
	normal = gl_NormalMatrix * gl_Normal;
	light = (gl_ModelViewMatrix * vec4(lightDir, 0)).xyz;
	shadowPos = shadowMVP * gl_Vertex;
}