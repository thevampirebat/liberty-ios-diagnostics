#version 450
vec2 points[3] = vec2[](vec2(0.0,-0.75),vec2(0.75,0.75),vec2(-0.75,0.75));
void main() { gl_Position = vec4(points[gl_VertexIndex],0.0,1.0); }
