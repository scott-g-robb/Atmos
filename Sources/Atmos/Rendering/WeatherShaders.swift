let weatherShaderSource = """
  #include <metal_stdlib>
  using namespace metal;
  struct WeatherUniforms {
      float2 viewSize; float time; float opacity;
      float4 light; float4 surface; float4 details; float4 cursor; float4 screen; float4 atmosphere; float4 pointer; float4 reflectionRect; float4 viewport; float4 climate;
  };
  struct WeatherParticle { float4 rect; float4 motion; float4 color; float4 life; };
  struct WeatherOut {
      float4 position [[position]]; float2 uv; float4 color;
      float seed; float kind [[flat]]; float2 world; float2 life; float style; float background [[flat]];float4 fluid;float4 neighbour;uint sampleIndex [[flat]];float2 flow [[flat]];
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
  static float2 blobWave(float phase) {
      float2 wave=1.0-4.0*abs(fract(float2(phase,phase+0.25))-0.5);
      return wave*(1.5-0.5*wave*wave);
  }
  static float3 liquidKernel(float2 delta,float h,float4 lobes,float2 axis,float strain) {
      float2 perpendicular=float2(-axis.y,axis.x);
      float2 p=delta/h;
      // A moving packet narrows across its flow; low-frequency lobes make the
      // merged fluid asymmetric without a noisy texture or per-pixel trig.
      p+=perpendicular*dot(p,perpendicular)*strain;
      float x=p.x,y=p.y,r2=dot(p,p);
      if(r2>=1.0)return float3(0);
      float2 h2=float2(x*x-y*y,2*x*y);
      float2 h3=float2(x*(x*x-3*y*y),y*(3*x*x-y*y));
      float2 h4=float2(h2.x*h2.x-h2.y*h2.y,2*h2.x*h2.y);
      float2 l4=float2(lobes.y,-lobes.x);
      float modulation=1+0.32*dot(h2,lobes.xy)+0.60*dot(h3,lobes.zw)+0.26*dot(h4,l4);
      float base=1-r2,q=max(0.0,base*modulation);
      float2 dm=float2(
        0.32*(2*x*lobes.x+2*y*lobes.y)+0.60*(3*(x*x-y*y)*lobes.z+6*x*y*lobes.w),
        0.32*(-2*y*lobes.x+2*x*lobes.y)+0.60*(-6*x*y*lobes.z+3*(x*x-y*y)*lobes.w));
      dm+=1.04*float2(h3.x*l4.x+h3.y*l4.y,-h3.y*l4.x+h3.x*l4.y);
      float2 gradient=(-2*p*modulation+base*dm)*(3*q*q);
      gradient=(gradient+perpendicular*dot(gradient,perpendicular)*strain)/h;
      return float3(q*q*q,gradient);
  }
  static float foamAt(float2 world,float amount,float time) {
      // Aeration follows physical contact; white coverage has no wallpaper/noise texture.
      return smoothstep(0.08,0.55,amount);
  }
  static float birdSegment(float2 p,float2 a,float2 b,float ra,float rb) {
      float2 d=b-a;float t=clamp(dot(p-a,d)/max(dot(d,d),0.00001),0.0,1.0);
      return mix(ra,rb,t)-length(p-a-d*t);
  }
  static float birdWing(float2 p,float2 root,float2 bend,float2 tip,float width) {
      float shape=-2;
      float2 previous=root;
      for(int k=1;k<=5;k++) {
          float t=float(k)/5.0;float2 next=(1-t)*(1-t)*root+2*(1-t)*t*bend+t*t*tip;
          float ra=width*pow(1-(t-0.2),0.65),rb=width*pow(max(0.0,1-t),0.65)+0.005;
          shape=max(shape,birdSegment(p,previous,next,ra,rb));previous=next;
      }
      return shape;
  }
  vertex WeatherOut weatherVertex(uint id [[vertex_id]],uint instance [[instance_id]],
      constant WeatherParticle *particles [[buffer(0)]],constant WeatherUniforms &u [[buffer(1)]]) {
      WeatherParticle p=particles[instance]; float2 uv=float2(id&1,id>>1); float2 q=(uv-0.5)*p.rect.zw;
      bool streak=p.motion.w<0.5 || (p.motion.w>4.5 && p.motion.w<6.5) || (p.motion.w>7.5 && p.motion.w<8.5) || (p.motion.w>10.5 && p.motion.w<11.5);
      if(p.motion.w==13.0) {float a=p.life.w; q=float2(cos(a)*q.x-sin(a)*q.y,sin(a)*q.x+cos(a)*q.y);}
      if(streak) {float2 axis=normalize(p.motion.xy+float2(0,-0.001));q=float2(-axis.y,axis.x)*q.x+axis*q.y;}
      float2 world=p.rect.xy+q;
      if(p.motion.w==9.0) {
          float reach=max(1.65,p.rect.z*2.2);
          float2 flow=p.motion.z<0 ? p.motion.xy*0.008 : float2(0);
          flow*=min(1.0,6.0/max(0.001,length(flow)));
          world=p.rect.xy+(uv-0.5)*(reach*2.0+abs(flow));
      }
      WeatherOut out;out.sampleIndex=instance;out.fluid=p.rect;
      out.flow=p.motion.w==9 && p.motion.z<0 ? p.motion.xy*0.008 : float2(0);
      out.flow*=min(1.0,6.0/max(0.001,length(out.flow)));out.neighbour=p.color;
      out.position=float4(world/u.viewSize*2.0-1.0,0,1);out.uv=uv;out.world=world;
      float fade=smoothstep(0.0,0.5,p.life.x)*smoothstep(0.0,0.8,p.life.y-p.life.x);
      if(p.motion.w<1.5 || p.motion.w==9.0)fade=1.0;
      if(p.motion.w==11.0)fade=pow(saturate(1.0-p.life.x/p.life.y),1.3);
      if(p.motion.w>4.5 && p.motion.w<6.5)fade=pow(saturate(1.0-p.life.x/max(p.life.y,0.01)),1.6);
      out.color=float4(p.color.rgb*mix(float3(1),u.light.rgb,0.18),p.color.a*fade*u.opacity);
      if(p.motion.w==9.0) {
          float speed=length(p.motion.xy);
          out.uv=speed>1 ? p.motion.xy/speed : float2(1,0);
          out.fluid.w=min(0.35,speed/2200.0);
          float phase=abs(p.motion.z)*1.732+u.time*0.38;
          out.neighbour=float4(blobWave(phase)*(0.7+0.5*fract(abs(p.motion.z)*11.13)),
            blobWave(phase*0.73+0.19)*(0.35+0.65*fract(abs(p.motion.z)*3.713)));
      }
      out.seed=p.motion.z;out.kind=p.motion.w;out.life=p.life.xy;out.style=p.life.w;out.background=p.life.z;return out;
  }
  fragment float4 weatherFragment(WeatherOut in [[stage_in]],constant WeatherUniforms &u [[buffer(1)]], constant float4 *blockers [[buffer(3)]],constant float4 *smoke [[buffer(4)]],constant float4 *windows [[buffer(5)]],texture2d<float> scene [[texture(0)]],constant float4 *liquid [[buffer(6)]]) {
      if(in.world.y>=u.screen.z)discard_fragment();
      if(in.kind==13.0 || (in.kind==2.0 && in.style>0.5 && in.background>0.5)) {
          for(int i=0;i<int(u.screen.w);i++) {
              float4 b=windows[i];float2 centre=(b.xy+b.zw)*0.5,halfSize=(b.zw-b.xy)*0.5;
              float corner=min(18.0,min(halfSize.x,halfSize.y));
              float2 q=abs(in.world-centre)-halfSize+corner;
              if(length(max(q,0.0))+min(max(q.x,q.y),0.0)<=corner)discard_fragment();
          }
      }
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
      if(in.kind==13.0) {
          float flap=0.25+0.75*abs(sin(u.time*(8.0+in.seed*3)+in.seed*39));
          float2 q=p;q.x/=flap;
          float upper=1.0-length((abs(q)-float2(0.42,0.22))*float2(2.0,2.5));
          float lower=1.0-length((abs(q)-float2(0.3,-0.38))*float2(2.7,3.5));
          // Two scalloped pairs with dark borders, vein detail and pale margin spots.
          upper=1.0-length((float2(abs(q.x),q.y)-float2(0.43,0.22))*float2(2.0,2.5));
          lower=1.0-length((float2(abs(q.x),q.y)-float2(0.3,-0.38))*float2(2.7,3.5));
          float shape=max(upper,lower);float wings=smoothstep(-0.04,0.05,shape);
          float veins=pow(abs(sin(atan2(q.y,q.x)*6+in.seed*3)),12.0);
          color=mix(float3(0.13,0.11,0.10),color,smoothstep(0.04,0.22,shape));
          color*=1-veins*0.35;float body=exp(-q.x*q.x*350.0)*smoothstep(0.75,0.3,abs(q.y));
          float a=max(wings,body)*alpha;
          return float4(mix(color,float3(0.14,0.12,0.10),body)*a,a);
      }
      if(in.kind==14.0) {
          float facing=sign(in.background);float species=abs(in.background)-1;
          float2 q=p*float2(facing,1);
          bool perched=in.style>0.5;
          float flap=sin(u.time*(9.0+in.seed*2.5)+in.seed*37);
          bool swallow=species>2.5;
          float body=0.32-length((q-float2(0,-0.04))*float2(swallow?0.90:1.02,1.65));
          float head=(swallow?0.15:0.18)-length(q-float2(0.32,0.14));
          float tail=birdSegment(q,float2(-0.23,-0.02),float2(-0.74,swallow?-0.25:-0.10),0.12,0.012);
          if(swallow)tail=max(tail,birdSegment(q,float2(-0.24,-0.02),float2(-0.79,0.09),0.09,0.008));
          float wing;
          float2 root=float2(-0.04,0.09),bend,tip;
          if(perched) {
              wing=0.24-length((q-float2(-0.10,-0.01))*float2(0.9,1.7));
          } else {
              bend=float2(-0.32,0.18+flap*0.42);
              tip=float2(swallow?-0.86:-0.74,0.14+flap*(swallow?0.70:0.62));
              wing=birdWing(q,root,bend,tip,swallow?0.13:0.16);
              // Three tapered primaries fan from the wrist; no straight rectangular wing ends.
              for(int k=0;k<3;k++) {
                  float f=float(k);
                  float2 wrist=mix(bend,tip,0.55);
                  float2 feather=tip+float2(-0.03*f,-0.045*f*(flap>=0?1:-1));
                  wing=max(wing,birdSegment(q,wrist,feather,0.055-f*0.008,0.006));
              }
          }
          float beak=birdSegment(q,float2(0.44,0.12),float2(0.64,0.09),0.055,0.005);
          float feet=-1;
          if(perched) {
              feet=max(birdSegment(q,float2(0.08,-0.20),float2(0.13,-0.44),0.022,0.014),birdSegment(q,float2(-0.06,-0.20),float2(-0.10,-0.44),0.022,0.014));
              feet=max(feet,birdSegment(q,float2(-0.13,-0.44),float2(0.22,-0.44),0.015,0.012));
          }
          float shape=max(max(body,head),max(max(tail,wing),max(beak,feet)));
          float aa=max(fwidth(shape),0.009);float a=smoothstep(-aa,aa,shape)*alpha;
          float3 back=species<0.5?float3(0.44,0.32,0.22):species<1.5?float3(0.37,0.39,0.27):species<2.5?float3(0.30,0.48,0.57):float3(0.14,0.23,0.34);
          float3 belly=species<0.5?float3(0.78,0.71,0.56):species<1.5?float3(0.89,0.39,0.18):species<2.5?float3(0.84,0.83,0.43):float3(0.90,0.88,0.78);
          color=back;
          float chest=exp(-dot((q-float2(0.12,-0.12))*float2(3.7,6),(q-float2(0.12,-0.12))*float2(3.7,6)));
          color=mix(color,belly,chest);
          float brow=birdSegment(q,float2(0.20,0.21),float2(0.43,0.22),0.032,0.018);
          if(species<0.5)color=mix(color,float3(0.86,0.78,0.61),smoothstep(-0.01,0.015,brow));
          if(species>1.5 && species<2.5)color=mix(color,float3(0.24,0.44,0.63),smoothstep(0.15,0.26,q.y));
          float wingMask=smoothstep(-aa,aa,wing);
          color=mix(color,back*0.78,wingMask*0.65);
          float bars=pow(0.5+0.5*sin((q.x+q.y*0.4)*32),14.0)*wingMask;
          color+=float3(0.16,0.14,0.10)*bars*0.55;
          float eye=1-smoothstep(0.015,0.038,length(q-float2(0.36,0.17)));color=mix(color,float3(0.025),eye);
          color=mix(color,float3(0.20,0.16,0.11),smoothstep(-aa,aa,max(beak,feet)));
          return weatherInk(color,a,a*0.25);
      }
      if(in.kind==9.0 || in.kind==5.0) {
          float shape;
          if(in.kind==9.0) {
              float h=max(1.1,in.fluid.z*1.8)*1.35;
              float2 d=in.world-in.fluid.xy;
              float flow2=dot(in.flow,in.flow);
              if(flow2>0.001)d-=in.flow*clamp(dot(d,in.flow)/flow2,-0.5,0.5);
              float3 sample=liquidKernel(d,h,in.neighbour,in.uv,in.fluid.w);
              float density=sample.x;
              float2 gradient=sample.yz;
              for(uint k=0;k<8;k++) {
                  float4 n=liquid[in.sampleIndex*8+k];if(n.w<0.5)continue;
                  float nh=max(1.1,n.z*3.6)*1.35;float2 delta=in.world-n.xy;
                  if(flow2>0.001)delta-=in.flow*clamp(dot(delta,in.flow)/flow2,-0.5,0.5);
                  float3 neighbour=liquidKernel(delta,nh,in.neighbour,in.uv,in.fluid.w);
                  density+=neighbour.x;gradient+=neighbour.yz;
              }
              float aa=max(length(gradient)*length(dfdx(in.world))*0.7,0.08);
              shape=smoothstep(0.62-aa,0.62+aa,density);
              if(shape<0.005)discard_fragment();
              p=-gradient/max(0.3,length(gradient))*0.7*(1-smoothstep(0.8,2.4,density));
          } else {shape=1-smoothstep(0.70,1.05,radius);}
          float3 normal=float3(p*0.8,sqrt(max(0.0,1.0-dot(p,p)*0.64)));
          float2 uv=float2(in.world.x,u.screen.y-in.world.y)/u.screen.xy;
          uv+=normal.xy*float2(0.018,-0.03);
          uv=u.reflectionRect.xy+uv*u.reflectionRect.zw;
          constexpr sampler waterSample(coord::normalized,address::clamp_to_edge,filter::linear);
          float3 reflected=scene.sample(waterSample,uv).rgb;
          float fresnel=0.12+0.65*pow(1-normal.z,3.0);
          float glint=exp(-dot(p-float2(-0.28,0.3),p-float2(-0.28,0.3))*38.0);
          float3 water=mix(reflected,float3(0.12,0.21,0.28),0.12);
          water+=float3(0.7,0.87,1)*(glint*0.14+fresnel*0.16);
          float froth=foamAt(in.world,in.style,u.time);
          water=mix(water,float3(1.0),froth);
          float a=shape*mix(alpha*(0.72+fresnel*0.24),0.98*alpha,froth);
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
      out.position=float4((out.world-u.viewport.xy)/u.viewSize*2.0-1.0,0,1);return out;
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
      float2 world=round(in.world*256.0)/256.0;
      if(world.y>=u.screen.z)discard_fragment();
      for(int i=0;i<int(u.details.z);i++){float4 b=blockers[i];if(world.x>=b.x && world.x<=b.z && world.y>=b.y && world.y<=b.w)discard_fragment();}
      int count=int(u.details.x);float column=clamp((world.x-u.surface.x)/u.surface.z*(count-1),0.0,float(count-1)-0.0001);
      float depth=waterHeight(heights,count,column);
      if(u.surface.y>0.5){float edge=min(world.x-u.surface.x,u.surface.x+u.surface.z-world.x);depth*=smoothstep(0.0,10.0,edge);}
      if(distance(world,u.cursor.xy)<11.0)discard_fragment();
      float y=world.y-u.surface.y;
      float2 pixel=float2(length(dfdx(in.world)),length(dfdy(in.world)));
      float step=pixel.x*(count-1)/u.surface.z*0.5;
      float lo=waterHeight(heights,count,max(0.0,column-step));
      float hi=waterHeight(heights,count,min(float(count-1)-0.0001,column+step));
      if(u.surface.y>0.5) {
          lo*=smoothstep(0.0,10.0,min(world.x-pixel.x*0.5-u.surface.x,u.surface.x+u.surface.z-world.x+pixel.x*0.5));
          hi*=smoothstep(0.0,10.0,min(world.x+pixel.x*0.5-u.surface.x,u.surface.x+u.surface.z-world.x-pixel.x*0.5));
      }
      float aa=max(pixel.y+abs(hi-lo),0.45*pixel.y);
      float coverage=smoothstep(-aa,aa,depth-y)*smoothstep(0.0,0.35,depth);if(coverage<0.001)discard_fragment();
      float slope=(waterHeight(heights,count,min(float(count-1)-0.0001,column+0.6))-waterHeight(heights,count,max(0.0,column-0.6)))/4.8;
      float2 normal=float2(-slope,0.025*sin(world.x*0.032+u.time*1.4));float rings=0;
      for(int r=0;r<int(u.details.y);r++) {
          WaterRipple ripple=ripples[r];if(abs(ripple.point.y-u.surface.y)>4.0)continue;
          float2 d=float2(world.x-ripple.point.x,(y-depth*0.6)*2.8);
          float outer=ripple.age*95.0+128.0;
          if(dot(d,d)>outer*outer)continue;
          float radius=length(d);float travel=radius-ripple.age*95.0;
          if(abs(travel)*0.095+ripple.age*2.0>12.0)continue;
          float envelope=exp(-abs(travel)*0.095-ripple.age*2.4)*ripple.strength*smoothstep(0.015,0.12,ripple.age);float wave=cos(travel*0.29)*envelope;
          normal+=normalize(d+0.001)*wave*0.06;rings+=wave;
      }
      rings=rings/(1+abs(rings));
      // Orthographic desktop projected into a finite reflection band above the waterline.
      float horizon=u.surface.y+depth;
      float reach=min(420.0,max(24.0,u.screen.y-horizon));
      float reflectedY=horizon+(1.0-saturate(y/max(depth,0.1)))*reach;
      float2 reflectionUV=float2(world.x,u.screen.y-reflectedY)/u.screen.xy;
      reflectionUV+=clamp(normal,float2(-1),float2(1))*float2(3.0,2.0)/u.screen.xy;
      reflectionUV = u.reflectionRect.xy + reflectionUV*u.reflectionRect.zw;
      constexpr sampler linearSample(coord::normalized,address::clamp_to_edge,filter::linear);
      float3 reflected=scene.sample(linearSample,reflectionUV).rgb;
      reflected=reflected*0.6+scene.sample(linearSample,reflectionUV+float2(0.0012,0.0015)).rgb*0.2+scene.sample(linearSample,reflectionUV-float2(0.0012,0.0015)).rgb*0.2;
      float2 cursor=u.cursor.xy-float2(4,-8);
      float cursorHeight=u.pointer.y*0.5;
      float cursorTop=depth-saturate((cursor.y-horizon)/reach)*depth+u.pointer.w*0.5;
      float2 pointerUV=float2((world.x-cursor.x+u.pointer.z)/max(1.0,u.pointer.x),1.0-(cursorTop-y)/max(1.0,cursorHeight));
      if(all(pointerUV>=0.0) && all(pointerUV<=1.0) && u.pointer.x>0 && cursor.y>=u.surface.y-12 && cursor.y<=horizon+reach) {
          float4 mouse=pointerImage.sample(linearSample,pointerUV);
          reflected=mix(reflected,mouse.rgb,max(0.0,mouse.a)*0.82);
      }
      float fresnel=0.08+0.65*pow(saturate(1.0-y/max(depth,0.01)),3.0);
      float meniscus=exp(-abs(depth-y)*2.5);float darkLine=exp(-abs(depth-y-0.9)*3.2);
      float3 color=mix(float3(0.12,0.21,0.28),reflected,0.90+fresnel*0.08);
      color=mix(color,color*0.45,darkLine*0.3);
      color*=1.0-min(0.30,max(0.0,-rings)*0.16);
      color+=float3(0.7,0.87,1.0)*(meniscus*0.4+max(0.0,rings)*0.22);
      float froth=foamAt(world,u.climate.x*exp(-abs(world.x-u.climate.y)/max(1.0,u.climate.z)),u.time);
      color=mix(color,float3(1.0),froth);
      float alpha=coverage*(0.59+fresnel*0.22+meniscus*0.2+froth*0.1)*u.opacity;
      alpha=max(alpha,coverage*froth*0.98*u.opacity);
      return float4(color*alpha,alpha);
  }

  """
