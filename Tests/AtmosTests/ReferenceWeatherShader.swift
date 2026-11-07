let referenceWeatherShaderSource = """
  #include <metal_stdlib>
  using namespace metal;
  struct WeatherUniforms {
      float2 viewSize; float time; float opacity;
      float4 light; float4 surface; float4 details; float4 cursor; float4 screen; float4 atmosphere; float4 pointer; float4 reflectionRect;
  };
  struct WeatherParticle { float4 rect; float4 motion; float4 color; float4 life; };
  struct WeatherOut {
      float4 position [[position]]; float2 uv; float4 color;
      float seed; float kind [[flat]]; float2 world; float2 life; float style;
  };
  struct WaterOut { float4 position [[position]]; float2 world; };
  struct WaterRipple { float2 point; float age; float strength; };
  static float weatherHash(float2 p) {
      p = fract(p * float2(123.34,456.21)); p += dot(p,p+45.32); return fract(p.x*p.y);
  }
  static float weatherNoise(float2 p) {
      float2 i=floor(p),f=fract(p); f=f*f*(3.0-2.0*f);
      return mix(mix(weatherHash(i),weatherHash(i+float2(1,0)),f.x),mix(weatherHash(i+float2(0,1)),weatherHash(i+1),f.x),f.y);
  }
  // Two tones in one premultiplied pass: pale cores read on dark desktops; shaded edges read on light ones.
  static float4 smokeAt(float2 world,constant float4 *cells,constant WeatherUniforms &u) {
      if(u.atmosphere.x<3)return float4(0,0,1,0);
      float2 g=clamp(world/u.atmosphere.z,float2(0),u.atmosphere.xy-1.001);
      int2 a=int2(g);float2 f=fract(g);int w=int(u.atmosphere.x);
      return mix(mix(cells[a.y*w+a.x],cells[a.y*w+a.x+1],f.x),mix(cells[(a.y+1)*w+a.x],cells[(a.y+1)*w+a.x+1],f.x),f.y);
  }
  static float volumeNoise(float3 p) {
      float a=weatherNoise(p.xy+float2(p.z*0.73,p.z*0.41));
      float b=weatherNoise(p.yz*2.13+float2(p.x*0.21,p.x*0.37));
      return a*0.68+b*0.32;
  }
  static float4 weatherInk(float3 color,float light,float shadow) {
      light=saturate(light); shadow=saturate(shadow);
      return float4(color*light+float3(0.09,0.14,0.20)*shadow*(1.0-light),light+shadow*(1.0-light));
  }
  vertex WeatherOut weatherVertex(uint id [[vertex_id]],uint instance [[instance_id]],
      constant WeatherParticle *particles [[buffer(0)]],constant WeatherUniforms &u [[buffer(1)]]) {
      WeatherParticle p=particles[instance]; float2 uv=float2(id&1,id>>1); float2 q=(uv-0.5)*p.rect.zw;
      bool streak=p.motion.w<0.5 || (p.motion.w>4.5 && p.motion.w<6.5) || (p.motion.w>7.5 && p.motion.w<8.5) || (p.motion.w>10.5 && p.motion.w<11.5);
      if(streak) {float2 axis=normalize(p.motion.xy+float2(0,-0.001));q=float2(-axis.y,axis.x)*q.x+axis*q.y;}
      float2 world=p.rect.xy+q; WeatherOut out;
      out.position=float4(world/u.viewSize*2.0-1.0,0,1);out.uv=uv;out.world=world;
      float fade=smoothstep(0.0,0.5,p.life.x)*smoothstep(0.0,0.8,p.life.y-p.life.x);
      if(p.motion.w<1.5 || p.motion.w==9.0)fade=1.0;
      if(p.motion.w==11.0)fade=pow(saturate(1.0-p.life.x/p.life.y),1.3);
      if(p.motion.w>4.5 && p.motion.w<6.5)fade=pow(saturate(1.0-p.life.x/max(p.life.y,0.01)),1.6);
      out.color=float4(p.color.rgb*mix(float3(1),u.light.rgb,0.18),p.color.a*fade*u.opacity);
      out.seed=p.motion.z;out.kind=p.motion.w;out.life=p.life.xy;out.style=p.life.w;return out;
  }
  fragment float4 weatherFragment(WeatherOut in [[stage_in]],constant WeatherUniforms &u [[buffer(1)]], constant float4 *blockers [[buffer(3)]],constant float4 *smoke [[buffer(4)]],texture2d<float> scene [[texture(0)]]) {
      if(in.world.y>=u.screen.z)discard_fragment();
      float2 p=in.uv*2.0-1.0;float radius=length(p);float alpha=in.color.a;float3 color=in.color.rgb;
      if(in.kind<0.5) {
          float end=pow(saturate(1.0-abs(p.y)),0.35);float taper=0.4+0.6*in.uv.y;
          float edge=exp(-p.x*p.x*3.0)*end*taper;
          float core=exp(-p.x*p.x*32.0)*end*taper;
          return weatherInk(color,core*alpha,edge*alpha*0.45);
      }
      if(in.kind<1.5) {
          float hex=max(abs(p.y),abs(p.x)*0.866+abs(p.y)*0.5);
          float shape=1.0-smoothstep(0.67,1.0,hex);
          color*=0.66+0.34*saturate(0.5-p.x*0.4+p.y*0.4);
          color+=0.3*exp(-length(p-float2(-0.24,0.3))*8.0);
          return weatherInk(color,shape*alpha*0.88,shape*alpha*0.48);
      }
      if(in.kind==2.0 || in.kind==7.0 || in.kind==12.0) {
          bool bank=in.kind==7.0;bool cloud=in.kind==12.0;bool storm=cloud && in.style>0.5;
          if(bank) for(int i=0;i<int(u.details.z);i++){float4 b=blockers[i];if(in.world.x>=b.x && in.world.x<=b.z && in.world.y>=b.y && in.world.y<=b.w)discard_fragment();}
          float4 flow=smokeAt(in.world,smoke,u);
          float2 advected=in.world*0.011-flow.xy*0.018+float2(-u.time*0.018,in.seed*19.0);
          float envelope;
          if(cloud) {
              float lower=0.12+weatherNoise(float2(in.world.x*0.009-u.time*0.012,7.3))*0.42;
              envelope=smoothstep(lower-0.16,lower+0.2,in.uv.y);
          } else if(bank) {
              envelope=smoothstep(0.0,0.09,min(in.uv.x,1.0-in.uv.x))*smoothstep(0.0,0.11,in.uv.y)*(1.0-smoothstep(0.30,0.98,in.uv.y));
          } else { envelope=exp(-dot(p*float2(1,1.15),p*float2(1,1.15))*2.6); }
          if(!cloud)envelope*=smoothstep(0.0,0.20,min(min(in.uv.x,1-in.uv.x),min(in.uv.y,1-in.uv.y)));
          float transmittance=1;float3 scattering=0;
          // Integrate density along a short 3D ray, with light extinction within each billow.
          for(int sample=0;sample<6;sample++) {
              float z=(float(sample)+0.5)/6.0;
              float3 pos=float3(advected+float2(z*0.43,z*0.12),z*2.8+in.seed*8);
              float n=volumeNoise(pos);float shape=smoothstep(0.22,0.77,n);
              float density=shape*envelope*mix(0.18,1.0,saturate(flow.z*1.6));
              float absorb=1.0-exp(-density*(storm?0.83:0.39));
              float lit=0.35+0.65*saturate(n*0.85+z*0.22);
              float3 tint=storm ? mix(float3(0.10,0.12,0.16),float3(0.38,0.41,0.46),lit) : mix(color*0.60,color,lit);
              if(storm)tint+=float3(0.48,0.55,0.72)*u.atmosphere.w;
              scattering+=transmittance*absorb*tint;transmittance*=1.0-absorb;
          }
          float a=(1-transmittance)*alpha;
          float3 rgb=scattering*alpha;
          // A soft underside keeps pale smoke readable on white without a hard outline.
          return float4(rgb,a);
      }
      if(in.kind==9.0 || in.kind==5.0) {
          float shape=1-smoothstep(0.72,1.0,radius);
          float3 normal=float3(p*0.8,sqrt(max(0.0,1.0-dot(p,p)*0.64)));
          float2 uv=float2(in.world.x,u.screen.y-in.world.y)/u.screen.xy;
          uv+=normal.xy*float2(0.018,-0.03);
          uv=u.reflectionRect.xy+uv*u.reflectionRect.zw;
          constexpr sampler waterSample(coord::normalized,address::clamp_to_edge,filter::linear);
          float3 reflected=scene.sample(waterSample,uv).rgb;
          float fresnel=0.12+0.65*pow(1-normal.z,3.0);
          float glint=exp(-dot(p-float2(-0.28,0.3),p-float2(-0.28,0.3))*38.0);
          float3 water=mix(reflected,float3(0.12,0.21,0.28),0.12);
          water+=float3(0.7,0.87,1)*(glint*0.55+fresnel*0.22);
          float a=shape*alpha*(0.72+fresnel*0.24);
          return float4(water*a,a);
      }
      if(in.kind==11.0) {
          float end=1-smoothstep(0.9,1.0,abs(p.y));
          float glow=exp(-p.x*p.x*3.0)*0.42;float core=exp(-p.x*p.x*70.0);
          return float4((color*glow+float3(0.95,0.97,1)*core)*alpha*end,saturate((glow+core)*alpha*end));
      }
      if(in.kind<3.5) {
          float r2=dot(p,p);float sparkle=0.55+0.45*pow(0.5+0.5*sin(u.time*1.5+in.seed*49),2.0);
          float halo=exp(-r2*5.0);float core=exp(-r2*36.0);
          float cross=exp(-abs(p.x)*55.0-abs(p.y)*8.0)+exp(-abs(p.y)*55.0-abs(p.x)*8.0);
          return weatherInk(mix(color,float3(1,0.98,0.8),core),alpha*(core*0.9+halo*0.2+cross*0.15)*sparkle,halo*alpha*0.35);
      }
      if(in.kind<4.5) {
          float r2=dot(p,p);float pulse=0.68+0.32*sin(u.time*(1.1+in.seed*0.5)+in.seed*57.0);
          float cycle=u.time*(0.10+in.seed*0.07)+in.seed*37.0;float beat=fract(cycle);
          float dim=smoothstep(0.70,0.75,beat)*(1-smoothstep(0.83,0.90,beat));
          pulse*=1-dim*(0.85+0.15*sin(u.time*13+in.seed*11));
          float halo=exp(-r2*3.8)*0.3;float core=exp(-r2*65.0);
          float wing=exp(-dot((p-float2(0.22,0.05))*float2(5,12),(p-float2(0.22,0.05))*float2(5,12)))
              +exp(-dot((p+float2(0.22,-0.05))*float2(5,12),(p+float2(0.22,-0.05))*float2(5,12)));
          color=mix(color,float3(1,1,0.84),core);
          return weatherInk(color,alpha*(halo+core+wing*0.12)*pulse,alpha*exp(-r2*21.0)*0.6);
      }
      if(in.kind<6.5) {
          float curl=sin(p.y*3.0+in.seed*31.0+in.life.x*2.0)*0.13;
          float line=exp(-pow(p.x-curl,2.0)*16.0)*pow(saturate(1.0-abs(p.y)),0.3);
          return weatherInk(color,line*alpha*0.58,line*alpha*0.25);
      }
      // Slowly moving shafts of warm daylight, with suspended dust drawn in a separate small-particle pass.
      float shaft=exp(-p.x*p.x*5.5)*smoothstep(0.0,0.13,in.uv.y)*(1.0-smoothstep(0.7,1.0,in.uv.y));
      float striation=0.8+0.2*sin(p.x*17.0+in.seed*41.0+u.time*0.06);
      return weatherInk(color,shaft*alpha*striation,shaft*alpha*0.38);
  }
  vertex WaterOut waterVertex(uint id [[vertex_id]],constant WeatherUniforms &u [[buffer(1)]]) {
      float2 uv=float2(id&1,id>>1);WaterOut out;out.world=u.surface.xy+uv*u.surface.zw;
      out.position=float4(out.world/u.viewSize*2.0-1.0,0,1);return out;
  }
  static float waterHeight(constant float *h,int count,float column) {
      int i=min(count-2,int(column));float t=fract(column);
      float a=h[max(0,i-1)],b=h[i],c=h[i+1],d=h[min(count-1,i+2)];
      float result=0.5*((2*b)+(-a+c)*t+(2*a-5*b+4*c-d)*t*t+(-a+3*b-3*c+d)*t*t*t);
      return clamp(result,max(0.0,min(b,c)-0.2),max(b,c)+0.2);
  }
  fragment float4 waterFragment(WaterOut in [[stage_in]],constant float *heights [[buffer(0)]],
      constant WeatherUniforms &u [[buffer(1)]],constant WaterRipple *ripples [[buffer(2)]],
      constant float4 *blockers [[buffer(3)]],texture2d<float> scene [[texture(0)]],texture2d<float> pointerImage [[texture(1)]]) {
      if(in.world.y>=u.screen.z)discard_fragment();
      for(int i=0;i<int(u.details.z);i++){float4 b=blockers[i];if(in.world.x>=b.x && in.world.x<=b.z && in.world.y>=b.y && in.world.y<=b.w)discard_fragment();}
      int count=int(u.details.x);float column=clamp((in.world.x-u.surface.x)/u.surface.z*(count-1),0.0,float(count-1)-0.0001);
      float depth=waterHeight(heights,count,column);
      if(u.surface.y>0.5){float edge=min(in.world.x-u.surface.x,u.surface.x+u.surface.z-in.world.x);depth*=smoothstep(0.0,10.0,edge);}
      float y=in.world.y-u.surface.y;float aa=max(fwidth(y-depth),0.45);
      float coverage=smoothstep(-aa,aa,depth-y)*smoothstep(0.0,0.35,depth);if(coverage<0.001)discard_fragment();
      float slope=(waterHeight(heights,count,min(float(count-1)-0.0001,column+0.6))-waterHeight(heights,count,max(0.0,column-0.6)))/4.8;
      float2 normal=float2(-slope,0.025*sin(in.world.x*0.032+u.time*1.4));float rings=0;
      for(int r=0;r<int(u.details.y);r++) {
          WaterRipple ripple=ripples[r];if(abs(ripple.point.y-u.surface.y)>4.0)continue;
          float2 d=float2(in.world.x-ripple.point.x,(y-depth*0.6)*2.8);float radius=length(d);float travel=radius-ripple.age*95.0;
          float envelope=exp(-abs(travel)*0.095-ripple.age*2.0)*ripple.strength;float wave=cos(travel*0.29)*envelope;
          normal+=normalize(d+0.001)*wave*0.12;rings+=wave;
      }
      // Orthographic desktop projected into a finite reflection band above the waterline.
      float horizon=u.surface.y+depth;
      float reach=min(420.0,max(24.0,u.screen.y-horizon));
      float reflectedY=horizon+(1.0-saturate(y/max(depth,0.1)))*reach;
      float2 reflectionUV=float2(in.world.x,u.screen.y-reflectedY)/u.screen.xy;
      reflectionUV+=clamp(normal,float2(-1),float2(1))*float2(3.0,2.0)/u.screen.xy;
      reflectionUV = u.reflectionRect.xy + reflectionUV*u.reflectionRect.zw;
      constexpr sampler linearSample(coord::normalized,address::clamp_to_edge,filter::linear);
      float3 reflected=scene.sample(linearSample,reflectionUV).rgb;
      reflected=reflected*0.6+scene.sample(linearSample,reflectionUV+float2(0.0012,0.0015)).rgb*0.2+scene.sample(linearSample,reflectionUV-float2(0.0012,0.0015)).rgb*0.2;
      float2 cursor=u.cursor.xy-float2(4,-8);
      float cursorHeight=u.pointer.y*0.5;
      float cursorTop=depth-saturate((cursor.y-horizon)/reach)*depth+u.pointer.w*0.5;
      float2 pointerUV=float2((in.world.x-cursor.x+u.pointer.z)/max(1.0,u.pointer.x),1.0-(cursorTop-y)/max(1.0,cursorHeight));
      if(all(pointerUV>=0.0) && all(pointerUV<=1.0) && u.pointer.x>0 && cursor.y>=u.surface.y-12 && cursor.y<=horizon+reach) {
          float4 mouse=pointerImage.sample(linearSample,pointerUV);
          reflected=mix(reflected,mouse.rgb,max(0.0,mouse.a)*0.82);
      }
      float fresnel=0.08+0.65*pow(saturate(1.0-y/max(depth,0.01)),3.0);
      float meniscus=exp(-abs(depth-y)*2.5);float darkLine=exp(-abs(depth-y-0.9)*3.2);
      float3 color=mix(float3(0.12,0.21,0.28),reflected,0.90+fresnel*0.08);
      color=mix(color,color*0.45,darkLine*0.3);
      color+=float3(0.7,0.87,1.0)*(meniscus*0.4+max(0.0,rings)*0.055);
      float alpha=coverage*(0.59+fresnel*0.22+meniscus*0.2)*u.opacity;
      return float4(color*alpha,alpha);
  }

  """

// Atmos 0.14.0 cloud appearance, retained as a visual regression reference.
let originalCloudVolumeFragment = """
      if(in.kind==2.0 || in.kind==7.0 || in.kind==12.0) {
          bool bank=in.kind==7.0;bool cloud=in.kind==12.0;bool storm=cloud && in.style>0.5;
          if(bank) for(int i=0;i<int(u.details.z);i++){float4 b=blockers[i];if(in.world.x>=b.x && in.world.x<=b.z && in.world.y>=b.y && in.world.y<=b.w)discard_fragment();}
          float4 flow=smokeAt(in.world,smoke,u);
          float2 advected=in.world*0.011-flow.xy*0.018+float2(-u.time*(0.018+u.climate.z*0.0005),in.seed*19.0);
          float envelope;
          if(cloud) {
              float lower=0.12+weatherNoise(float2(in.world.x*0.009-u.time*0.012,7.3))*0.42;
              envelope=smoothstep(lower-0.16,lower+0.2,in.uv.y);
              if(u.climate.w>0.5) {
                  float patch=weatherNoise(float2(in.world.x*0.0018-u.time*u.climate.z*0.000025,1.7));
                  float threshold=1.0-u.climate.x;
                  // Near-overcast has almost no gaps; cover is never capped at the old 80%.
                  envelope*=smoothstep(threshold-0.06,threshold+0.06,patch);
              }
          } else if(bank) {
              envelope=smoothstep(0.0,0.09,min(in.uv.x,1.0-in.uv.x))*smoothstep(0.0,0.11,in.uv.y)*(1.0-smoothstep(0.30,0.98,in.uv.y));
          } else { envelope=exp(-dot(p*float2(1,1.15),p*float2(1,1.15))*2.6); }
          if(!cloud)envelope*=smoothstep(0.0,0.20,min(min(in.uv.x,1-in.uv.x),min(in.uv.y,1-in.uv.y)));
          if(envelope==0.0 || alpha==0.0)discard_fragment();
          float transmittance=1;float3 scattering=0;
          // Integrate density along a short 3D ray, with light extinction within each billow.
          for(int sample=0;sample<6;sample++) {
              float z=(float(sample)+0.5)/6.0;
              float3 pos=float3(advected+float2(z*0.43,z*0.12),z*2.8+in.seed*8);
              float n=volumeNoise(pos);float shape=smoothstep(0.22,0.77,n);
              float density=shape*envelope*mix(0.18,1.0,saturate(flow.z*1.6))*(1.0+u.climate.y*0.25);
              float absorb=1.0-exp(-density*(storm?0.83:0.39));
              float lit=0.35+0.65*saturate(n*0.85+z*0.22);
              float3 tint=storm ? mix(float3(0.10,0.12,0.16),float3(0.38,0.41,0.46),lit) : mix(color*0.60,color,lit);
              if(storm)tint+=float3(0.48,0.55,0.72)*u.atmosphere.w;
              scattering+=transmittance*absorb*tint;transmittance*=1.0-absorb;
          }
          float a=(1-transmittance)*alpha;
          float3 rgb=scattering*alpha;
          // A soft underside keeps pale smoke readable on white without a hard outline.
          return float4(rgb,a);
      }
  """
