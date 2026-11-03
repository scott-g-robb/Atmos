let smokeShaderSource = """
  #include <metal_stdlib>
  using namespace metal;
  struct SmokeParams { float4 shape;float4 motion;float4 input;float4 counts; };
  kernel void smokeAdvect(constant SmokeParams &u [[buffer(0)]],constant float4 *sources [[buffer(1)]],
      device const float4 *cells [[buffer(2)]],device float4 *spare [[buffer(3)]],uint2 p [[thread_position_in_grid]]) {
      uint w=uint(u.shape.x),h=uint(u.shape.y),i=p.y*w+p.x;
      float spacing=u.shape.z,dt=min(u.shape.w,0.05),time=u.motion.x,wind=u.motion.y;
      float2 b=clamp(float2(p)-cells[i].xy*dt/spacing,float2(0),float2(w,h)-1.001);
      uint2 a=uint2(b);float2 f=b-float2(a);
      float3 value=(cells[a.y*w+a.x].xyz*(1.0-f.x)+cells[a.y*w+a.x+1].xyz*f.x)*(1.0-f.y)
          +(cells[(a.y+1)*w+a.x].xyz*(1.0-f.x)+cells[(a.y+1)*w+a.x+1].xyz*f.x)*f.y;
      float2 world=float2(p)*spacing,previous=u.input.zw,segment=u.motion.zw-previous;
      float t=clamp(dot(world-previous,segment)/max(dot(segment,segment),0.001),0.0,1.0);
      float2 d=world-previous-segment*t;
      float influence=exp(-dot(d,d)/(spacing*spacing*2.0)),gain=min(dt*12.0,1.0)*influence;
      value.x+=(u.input.x*0.55-d.y*2.8)*gain;
      value.y+=(u.input.y*0.55+d.x*2.8)*gain;
      value.x+=(wind*0.025+sin(world.y*0.021+time*0.16)*3.5-value.x)*dt*0.45;
      value.y+=(cos(world.x*0.017+time*0.12)*2.5-value.y)*dt*0.45;
      value.xy=clamp(value.xy,float2(-360),float2(360));
      float exponent=-MAXFLOAT;
      for(uint s=0;s<uint(u.counts.x);s++) {
          float dx=abs(world.x-sources[s].x)/max(sources[s].z,1.0);
          float dy=abs(world.y-sources[s].y)/max(sources[s].w,1.0);
          if(dx<1.8 && dy<2.2)exponent=max(exponent,-dx*dx*3.0-dy*dy*2.0);
      }
      float target=exponent==-MAXFLOAT?0.0:exp(exponent);
      value.z=clamp(value.z+(target-value.z)*dt*0.32,0.0,1.0);
      if(p.x==0 || p.y==0 || p.x==w-1 || p.y==h-1)value.xy*=0.5;
      spare[i]=float4(value,0);
  }
  kernel void smokeDivergence(constant SmokeParams &u [[buffer(0)]],device const float4 *spare [[buffer(3)]],
      device float *pressure [[buffer(4)]],uint2 p [[thread_position_in_grid]]) {
      uint w=uint(u.shape.x),h=uint(u.shape.y),n=w*h,i=p.y*w+p.x;
      float divergence=0;
      if(p.x>0 && p.y>0 && p.x<w-1 && p.y<h-1)
          divergence=(spare[i+1].x-spare[i-1].x+spare[i+w].y-spare[i-w].y)/(2.0*u.shape.z);
      pressure[i]=0;pressure[n+i]=0;pressure[2*n+i]=divergence;
  }
  kernel void smokeJacobi(constant SmokeParams &u [[buffer(0)]],device float *pressure [[buffer(4)]],
      constant uint &iteration [[buffer(5)]],uint2 p [[thread_position_in_grid]]) {
      uint w=uint(u.shape.x),h=uint(u.shape.y),n=w*h,i=p.y*w+p.x;
      if(p.x==0 || p.y==0 || p.x==w-1 || p.y==h-1)return;
      uint from=(iteration&1u)*n,to=(1u-(iteration&1u))*n;
      pressure[to+i]=(pressure[from+i-1]+pressure[from+i+1]+pressure[from+i-w]+pressure[from+i+w]
          -pressure[2*n+i]*u.shape.z*u.shape.z)*0.25;
  }
  kernel void smokeProject(constant SmokeParams &u [[buffer(0)]],device float4 *cells [[buffer(2)]],
      device const float4 *spare [[buffer(3)]],device const float *pressure [[buffer(4)]],uint2 p [[thread_position_in_grid]]) {
      uint w=uint(u.shape.x),h=uint(u.shape.y),i=p.y*w+p.x;
      float4 value=spare[i];value.w=pressure[i];
      if(p.x>0 && p.y>0 && p.x<w-1 && p.y<h-1) {
          value.x-=(pressure[i+1]-pressure[i-1])/(2.0*u.shape.z);
          value.y-=(pressure[i+w]-pressure[i-w])/(2.0*u.shape.z);
      }
      cells[i]=value;
  }
  """
