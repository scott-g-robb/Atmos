let shaderSource = """
  #include <metal_stdlib>
  using namespace metal;

  struct Uniforms {
      float2 viewSize;
      float scale;
      float time;
      float columnWidth;
      int columnCount;
      float pileTop;
      int occluderCount;
      float2 origin;
      float pileBottom;
      float autumn;
      float4 light;
      float4 shadowTint;
      float4 rim;
      float4 shake;
  };

  struct Sprite {
      float2 position;
      float2 velocity;
      float size;
      float alpha;
      float soft;
      float tintAmount;
      float tintRed;
      float tintGreen;
      float tintBlue;
      float lump;
      float leaf;
      float turn;
      float flip;
      float turnSpeed;
      float flipSpeed;
  };

  struct SpriteOut {
      float4 position [[position]];
      float pointSize [[point_size]];
      float alpha;
      float soft;
      float4 tint;
      float3 light;
      float2 streak;
      float radius;
      float lump;
      float spin;
      float leaf;
      float turn;
      float flip;
      float reach;
      float turnSmear;
      float flipSmear;
      float samples;
  };


  static float hash(float2 p) {
      p = fract(p * float2(123.34, 456.21));
      p += dot(p, p + 45.32);
      return fract(p.x * p.y);
  }

  static float noise(float x) {
      float i = floor(x);
      float f = fract(x);
      return mix(hash(float2(i, 0.0)), hash(float2(i + 1.0, 0.0)), f * f * (3.0 - 2.0 * f));
  }

  /// Golden, amber, orange, rust or brown, a little lighter or darker.
  static float3 leafColor(float seed) {
      float k = fract(seed * 7.13);
      float3 c = k < 0.3 ? float3(0.97, 0.78, 0.22)
          : k < 0.55 ? float3(0.95, 0.56, 0.13)
          : k < 0.75 ? float3(0.86, 0.36, 0.11)
          : k < 0.9 ? float3(0.72, 0.2, 0.09)
          : float3(0.58, 0.38, 0.17);
      return c * (0.86 + 0.24 * fract(seed * 31.7));
  }

  /// Fallen leaves lying every which way: the topmost at each point shows, the gaps between them in shadow.
  static float3 litter(float2 point) {
      float2 cell = floor(point / 6.5);
      float top = -1.0;
      float rim = 0.0;
      float3 color = float3(0.34, 0.19, 0.08);
      for (int j = -1; j <= 1; j++) {
          for (int i = -1; i <= 1; i++) {
              for (int k = 0; k < 3; k++) {
                  float2 c = cell + float2(i, j) + float(k) * 0.37;
                  float2 d = point - (cell + float2(i, j) + float2(hash(c + 7.1), hash(c + 3.3))) * 6.5;
                  float angle = hash(c + 11.7) * 6.2832;
                  float2 q = float2(cos(angle) * d.x + sin(angle) * d.y, -sin(angle) * d.x + cos(angle) * d.y);
                  float size = 3.8 + 2.4 * hash(c + 2.9);
                  float t = q.x / size;
                  float inside = (1.0 - t * t) * size * 0.45 - abs(q.y);
                  float z = hash(c + 5.9);
                  if (inside > 0.0 && z > top) {
                      top = z;
                      rim = inside;
                      color = leafColor(hash(c + 0.5));
                  }
              }
          }
      }
      return color * (0.7 + 0.3 * smoothstep(0.0, 0.7, rim));
  }

  /// A leaf at one moment, `p` running across it from -0.5 to 0.5: its colour, premultiplied.
  static float4 leafAt(float2 p, float seed, float turn, float flip, float alpha, float3 light) {
      float across = max(abs(flip), 0.35);
      float2 r = float2(cos(turn) * p.x + sin(turn) * p.y, -sin(turn) * p.x + cos(turn) * p.y) * 2.0;
      r.y /= across;
      float inside;
      if (fract(seed * 13.7) < 0.4) {
          // A maple leaf: five pointed lobes around the stem.
          float2 m = r - float2(0.08, 0.0);
          float a = atan2(m.y, m.x);
          float reach = (0.5 + 0.44 * pow(abs(cos(a * 2.5)), 1.3)) * (0.82 + 0.18 * cos(a));
          inside = reach - length(m);
      } else {
          // An oval leaf, widest toward the stem and pointed at the tip.
          float t = (r.x + 0.88) / 1.82;
          float halfWidth = 2.1 * pow(saturate(t), 0.7) * pow(saturate(1.0 - t), 1.1) * (0.8 + 0.4 * fract(seed * 5.3));
          inside = min(halfWidth - abs(r.y), min(t, 1.0 - t) * 0.6);
      }
      float stem = 0.05 - max(abs(r.y) * across, max(-0.98 - r.x, r.x + 0.55));
      float shape = max(inside, stem);
      float edge = max(fwidth(shape), 1e-4);
      float a = smoothstep(-edge, edge, shape) * alpha;
      float3 color = leafColor(seed);
      color *= 0.76 + 0.24 * smoothstep(0.0, 0.22, inside);
      float vein = (1.0 - smoothstep(0.0, 0.045, abs(r.y) * across)) * step(-0.9, r.x) * step(r.x, 0.7);
      color = mix(color, color * 0.6, vein * 0.55);
      if (flip < 0.0) color = mix(color, float3(0.86, 0.74, 0.52), 0.28) * 0.9;
      // Night dims the leaves without draining their colour.
      color *= (0.8 + 0.2 * abs(flip)) * mix(float3(1.0), light, 0.4);
      return float4(color * a, a);
  }

  static float segmentDistance(float2 p,float2 a,float2 b) {
      float2 ab=b-a;return length(p-a-ab*clamp(dot(p-a,ab)/max(dot(ab,ab),0.0001),0.0,1.0));
  }
  static float hairCoverage(float2 p,float2 a,float2 b,float width,float aa) {
      float2 ab=b-a,d=p-a-ab*clamp(dot(p-a,ab)/max(dot(ab,ab),0.00001),0.0,1.0);
      return 1.0-smoothstep(width*width,(width+aa)*(width+aa),dot(d,d));
  }
  static float3 headProjection(float3 p,float2 yaw,float2 tilt) {
      p=float3(yaw.x*p.x+yaw.y*p.z,p.y,-yaw.y*p.x+yaw.x*p.z);
      return float3(p.x,tilt.x*p.y-tilt.y*p.z,tilt.y*p.y+tilt.x*p.z);
  }
  static float4 dandelionHeadAt(float2 p,float seed,float turn,float flip,float alpha,float3 light) {
      // A spherical set of seed stalks and tiny parachutes. Rotation changes
      // front/back overlap instead of flattening the head into a turning disk.
      constexpr float3 directions[40]={
          float3(0.2222049,0.9750000,0.0000000),float3(-0.2801759,0.9250000,0.2566641),float3(0.0423248,0.8750000,-0.4822692),float3(0.3438487,0.8250000,0.4484898),
          float3(-0.6223007,0.7750000,-0.1100762),float3(0.5811355,0.7250000,-0.3696708),float3(-0.1915407,0.6750000,0.7125217),float3(-0.3597954,0.6250000,-0.6927642),
          float3(0.7685089,0.5750000,0.2806582),float3(-0.7867126,0.5250000,0.3247435),float3(0.3729785,0.4750000,-0.7970333),float3(0.2709098,0.4250000,0.8637030),
          float3(-0.8020723,0.3750000,-0.4648173),float3(0.9236560,0.3250000,-0.2030632),float3(-0.5529549,0.2750000,0.7865214),float3(-0.1252155,0.2250000,-0.9662795),
          float3(0.7528493,0.1750000,0.6345022),float3(-0.9913095,0.1250000,0.0409938),float3(0.7068330,0.0750000,-0.7033933),float3(-0.0461770,0.0250000,0.9986204),
          float3(-0.6405089,-0.0250000,-0.7675437),float3(0.9882781,-0.0750000,0.1329714),float3(-0.8144201,-0.1250000,0.5666523),float3(0.2160944,-0.1750000,-0.9605614),
          float3(0.4844325,-0.2250000,0.8453994),float3(-0.9159610,-0.2750000,-0.2922165),float3(0.8585108,-0.3250000,-0.3966538),float3(-0.3578882,-0.3750000,0.8551556),
          float3(-0.3063648,-0.4250000,-0.8517721),float3(0.7789541,-0.4750000,0.4093965),float3(-0.8229903,-0.5250000,0.2169376),float3(0.4424882,-0.5750000,-0.6881709),
          float3(0.1322192,-0.6250000,0.7693459),float3(-0.5833358,-0.6750000,-0.4517680),float3(0.6863973,-0.7250000,-0.0568666),float3(-0.4291518,-0.7750000,0.4639005),
          float3(0.0027569,-0.8250000,-0.5651260),float3(0.3252750,-0.8750000,0.3585682),float3(-0.3783457,-0.9250000,-0.0350650),float3(0.1769994,-0.9750000,-0.1343362)
      };
      float ct=cos(turn),st=sin(turn);
      float2 r=float2(ct*p.x+st*p.y,-st*p.x+ct*p.y)*2.0;
      float2 centre=float2(0,0.12);
      float yawAngle=seed*9.7+turn*0.6,tiltAngle=flip*1.15;
      float2 yaw=float2(cos(yawAngle),sin(yawAngle)),tilt=float2(cos(tiltAngle),sin(tiltAngle));
      float aa=max(fwidth(r.x)*0.6,0.004);
      float3 root=headProjection(float3(0,-0.91,0.05),yaw,tilt);
      float2 bend=mix(centre,root.xy,0.55)+float2(0.045,0);
      float stem=max(hairCoverage(r,centre,bend,0.016,aa),hairCoverage(r,bend,root.xy,0.011,aa));
      float2 q=(r-centre)/0.115;
      float core=1.0-smoothstep(0.8,1.0,length(q));
      float coreZ=sqrt(saturate(1-dot(q,q)));
      float3 coreColor=mix(float3(0.26,0.23,0.12),float3(0.73,0.64,0.40),saturate(0.45-q.x*0.23+q.y*0.2+coreZ*0.35));
      float a=stem*0.8;float3 color=float3(0.39,0.43,0.20)*a;
      color=mix(color,coreColor,core);a=mix(a,1.0,core);
      float back=0,front=0;float3 backColor=float3(0),frontColor=float3(0);
      for(uint k=0;k<40;k++) {
          float3 direction=directions[k];
          float3 n=headProjection(direction,yaw,tilt);
          float reach=0.58*(0.92+0.08*fract(float(k)*0.618+seed*3.1));
          float3 tip=n*reach;
          float3 tangent=headProjection(normalize(cross(direction,float3(0.12,1,0.07))),yaw,tilt);
          float3 across=cross(n,tangent);
          float2 end=centre+tip.xy;
          float stalk=hairCoverage(r,centre+n.xy*0.08,end-n.xy*0.055,0.005,aa);
          float tuft=0;
          constexpr float2 ring[5]={float2(1,0),float2(0.309,0.951),float2(-0.809,0.588),float2(-0.809,-0.588),float2(0.309,-0.951)};
          for(uint spoke=0;spoke<5;spoke++) {
              float2 spread=(tangent.xy*ring[spoke].x+across.xy*ring[spoke].y)*0.078;
              tuft=max(tuft,hairCoverage(r,end-n.xy*0.06,end+spread,0.009,aa));
          }
          float coverage=stalk*0.32+tuft*0.68;
          float lit=0.35+0.65*saturate(dot(n,float3(-0.42,0.55,0.72)));
          float3 tint=mix(float3(0.52,0.56,0.48),float3(1.0,0.99,0.90),lit);
          if(n.z<0){back+=coverage*0.52;backColor+=tint*coverage*0.52;}
          else {front+=coverage;frontColor+=tint*coverage;}
      }
      float rear=1.0-exp(-back*0.72),near=1.0-exp(-front*0.85);
      float3 rearColor=backColor/max(back,0.001);
      // Rear filaments remain visible around the seed centre; the near cap lays
      // over them. Directional light and depth distinguish a globe from a disk.
      color+=rearColor*rear*(1-a);a+=rear*(1-a);
      color=color*(1-near)+frontColor/max(front,0.001)*near;a=a*(1-near)+near;
      color*=mix(float3(1),light,0.3)*alpha;a*=alpha;
      return float4(color,a);
  }
  // Clear silhouettes first; asymmetry, rolled edges and fine veins only reveal themselves up close.
  // All species share the leaves' actual translational and angular exposure blur.
  static float4 botanicalAt(float2 p, float seed, float turn, float flip, float alpha, float3 light, float style) {
      if(style<1.5)return leafAt(p,seed,turn,flip,alpha,light);
      float2 r=float2(cos(turn)*p.x+sin(turn)*p.y,-sin(turn)*p.x+cos(turn)*p.y)*2.0;
      r.y/=max(abs(flip),0.28);
      if(style>4.5 && style<5.5) {
          // Rotate in the horizontal rotor plane, then project its vertical depth.
          // The inverse projection keeps the stem fixed while the wing circles it.
          float lean=(seed-0.5)*smoothstep(0.16,0.28,abs(flip));
          float2 tilted=float2(cos(lean)*p.x+sin(lean)*p.y,-sin(lean)*p.x+cos(lean)*p.y);
          float2 rotor=float2(tilted.x,tilted.y/clamp(abs(flip),0.12,0.58))*2.0;
          r=float2(cos(turn)*rotor.x+sin(turn)*rotor.y,-sin(turn)*rotor.x+cos(turn)*rotor.y);
          r+=float2(-0.91,-0.20);
      }
      if(style>2.5 && style<3.5 && seed>2.0) {
          return dandelionHeadAt(p,seed,turn,flip,alpha,light);
      }
      float shape=-1;float3 color=float3(1);float vein=0;
      if(style<2.5 || (style>3.5 && style<4.5)) {
          bool rose=style>3.5;
          float u=clamp((r.x+0.84)/1.66,0.0,1.0);
          float bend=(seed-0.45)*0.22*sin(u*3.14159);
          float y=r.y-bend;
          float width=(rose?0.74:0.63)*pow(max(0.0,sin(u*3.14159)),rose?0.43:0.68)*(0.42+0.9*u);
          width*=0.88+0.22*seed;
          width*=1.0+0.055*sin(u*19.0+seed*31.0)+(y>0.0?0.08:-0.05);
          shape=min(width-abs(y),min(r.x+0.84,0.82-r.x));
          if(!rose) {
              // Sakura's split lip and narrow base distinguish it even at small sizes.
              float notch=length((r-float2(0.77,bend))*float2(1.0,1.7))-(0.16+seed*0.07);
              shape=min(shape,notch);
          } else {
              // A broad fan with an off-centre fold and a slightly curled, scalloped lip.
              shape=min(shape,0.79-r.x+0.045*cos(y*14.0+seed*5.0));
              shape-=0.035*sin(u*14.0+seed*9)*smoothstep(0.60,0.95,u);
          }
          float fanAngle=atan2(y,r.x+1.03);
          vein=pow(0.5+0.5*cos(fanAngle*(rose?34.0:42.0)+seed*3.0),24.0)*smoothstep(0.08,0.45,u);
          float fold=exp(-abs(y-(rose?0.16:-0.06)*sin(u*3.14159))*24.0);
          float rim=exp(-max(shape,0.0)*27.0);
          float3 base=rose?mix(float3(0.72,0.13,0.28),float3(0.98,0.49,0.58),seed):mix(float3(1.0,0.72,0.80),float3(1.0,0.94,0.92),seed);
          float3 root=rose?float3(0.46,0.035,0.16):float3(0.89,0.34,0.49);
          color=mix(root,base,smoothstep(0.02,0.72,u));
          color*=1.0-vein*0.12;
          color*=0.82+0.18*smoothstep(-0.25,0.35,y);
          color+=float3(1.0,0.83,0.80)*(fold*0.055+rim*(y>0?0.10:0.025));
          color*=1.0-exp(-abs(shape-0.05)*32.0)*0.09;
          if(flip<0)color=mix(color,rose?float3(0.98,0.66,0.66):float3(1,0.95,0.94),0.22);
      } else if(style<3.5) {
          // An airy, cupped parachute with individually bowed filaments and a hanging achene.
          shape=min(0.021-segmentDistance(r,float2(-0.65,-0.06),float2(0.12,0.0)),0.12-r.x);
          for(int k=0;k<11;k++) {
              float a=-1.42+float(k)*0.284;
              float2 tip=float2(0.24+0.43*cos(a),0.69*sin(a));
              tip.y*=0.88+0.12*sin(seed*17+float(k)*2.1);
              float2 middle=mix(float2(0.08,0),tip,0.5)+float2(-0.06,0.04*sin(a));
              float hair=min(segmentDistance(r,float2(0.08,0),middle),segmentDistance(r,middle,tip));
              shape=max(shape,0.014-hair);
              shape=max(shape,0.020-segmentDistance(r,tip,tip+float2(0.06,0.035*sin(a))));
          }
          float nut=0.095-length((r-float2(-0.70,-0.065))*float2(0.65,1.8));
          shape=max(shape,nut);
          color=mix(float3(0.47,0.29,0.12),float3(0.98,0.96,0.85),smoothstep(-0.62,-0.15,r.x));
      } else if(style<5.5) {
          // A maple samara: a curved, tapered wing growing from a heavy seed, with radial ribs.
          float u=clamp((r.x+0.70)/1.48,0.0,1.0);
          float centre=-0.19+u*0.55-0.16*sin(u*3.14159);
          float width=0.36*pow(max(0.0,sin(u*3.14159)),0.65)*(1.0-u*0.47);
          shape=min(width-abs(r.y-centre),min(r.x+0.70,0.78-r.x));
          float nut=0.17-length((r-float2(-0.66,-0.20))*float2(0.85,1.2));
          shape=max(shape,nut);
          shape=max(shape,0.026-segmentDistance(r,float2(-0.91,-0.20),float2(-0.66,-0.20)));
          float angle=atan2(r.y+0.22,r.x+0.86);
          vein=pow(0.5+0.5*sin(angle*80+seed*3),22.0);
          color=mix(float3(0.67,0.46,0.19),float3(0.88,0.73,0.38),seed);
          color*=0.89+0.11*smoothstep(-0.3,0.3,r.y-centre);
          color*=1-vein*0.18;
          color=mix(color,float3(0.38,0.23,0.10),smoothstep(-0.015,0.05,nut)*0.8);
          color+=float3(0.12,0.10,0.055)*exp(-max(shape,0.0)*35.0);
      } else {
          // Cottonwood is a loose, uneven tuft; its seed and curved fibres replace the old radial disk.
          for(int k=0;k<17;k++) {
              float a=float(k)*2.39996+seed*17;
              float reach=0.40+0.35*fract(sin(float(k)*31.7+seed*97)*1723.0);
              float2 tip=float2(cos(a)*reach,sin(a)*reach*0.74);
              float2 bend=tip*0.48+float2(sin(a)*0.18,cos(a)*0.19);
              float2 previous=float2(0);
              for(int j=1;j<=4;j++) {
                  float t=float(j)/4.0;
                  float2 next=2*(1-t)*t*bend+t*t*tip;
                  float strand=segmentDistance(r,previous,next);
                  shape=max(shape,(0.014-0.006*t)-strand);previous=next;
              }
          }
          float core=0.075-length((r-float2(-0.04,0))*float2(0.65,1.6));
          shape=max(shape,core);
          color=mix(float3(0.62,0.50,0.31),float3(0.98,0.97,0.89),smoothstep(0.03,0.17,length(r)));
          alpha*=0.90;
      }
      float edge=max(fwidth(shape),0.005);float a=smoothstep(-edge,edge,shape)*alpha;
      if(style>5.5)a=max(a*0.75,exp(-dot(r,r)*9.0)*alpha*0.12);
      color*=mix(float3(1),light,0.35)*(0.85+0.15*abs(flip));
      return float4(color*a,a);
  }
  static float3 botanicalLitter(float2 point,float style) {
      if(style<1.5)return litter(point);
      float n=hash(floor(point/3.5));
      if(style<2.5)return mix(float3(0.74,0.42,0.50),float3(1,0.83,0.87),n);
      if(style<3.5)return mix(float3(0.53,0.43,0.29),float3(0.91,0.89,0.78),n);
      if(style<4.5)return mix(float3(0.46,0.07,0.19),float3(0.93,0.38,0.49),n);
      if(style<5.5)return mix(float3(0.38,0.23,0.11),float3(0.77,0.58,0.28),n);
      return mix(float3(0.73,0.71,0.63),float3(0.97,0.95,0.87),n);
  }

  vertex SpriteOut spriteVertex(uint vid [[vertex_id]],
                                const device Sprite *sprites [[buffer(0)]],
                                constant Uniforms &u [[buffer(1)]]) {
      Sprite s = sprites[vid];
      if (s.leaf != 0.0) {
          SpriteOut out;
          // About a 1/40 s exposure: at 30 frames a second a falling leaf smears most of the way to where the next
          // frame shows it, so it glides instead of hopping. The sprite sits midway along the smear.
          float exposure = 0.024;
          float pixels = max(s.size * u.scale, 2.0);
          float2 travel = s.velocity * exposure;
          float extent = pixels * (u.autumn>4.5 && u.autumn<5.5 ? 1.85 : 1.0) + length(travel) * u.scale;
          out.position = float4((s.position - travel * 0.5 + u.shake.xy) / u.viewSize * 2.0 - 1.0, 0.0, 1.0);
          out.pointSize = extent;
          out.reach = extent / pixels;
          out.streak = travel / max(s.size, 0.001);
          out.turnSmear = s.turnSpeed * exposure;
          out.flipSmear = s.flipSpeed * exposure;
          // Enough moments along the smear that no copy of the leaf stands apart from the next.
          float motion = length(travel) * u.scale + (abs(out.turnSmear) + abs(out.flipSmear)) * pixels * 0.5;
          // Fast samaras need closer angular samples to keep the spinning wing
          // continuous. Other materials retain their existing sampling budget.
          float maximumSamples = u.autumn>4.5 && u.autumn<5.5 ? 32.0 : 8.0;
          out.samples = clamp(ceil(motion / 1.2), 1.0, maximumSamples);
          out.alpha = s.alpha;
          out.light = u.light.rgb;
          out.leaf = s.leaf;
          out.turn = s.turn;
          out.flip = s.flip;
          return out;
      }
      float pixels = s.size * u.scale;
      // About a 1/55 s exposure, capped so even the fastest grain stays a short smear and never reads as rain.
      float2 travel = s.velocity * 0.018;
      float smear = min(length(travel), s.size * (s.lump > 0.0 ? 1.2 : 2.2));
      float2 streak = smear > 0.25 ? normalize(travel) * smear * u.scale : float2(0.0);
      // A lump's ragged edge reaches past its nominal size.
      float reach = s.lump > 0.0 ? 1.3 : 1.0;
      float extent = max(pixels * reach + length(streak), 2.0);
      SpriteOut out;
      out.position = float4((s.position + u.shake.xy) / u.viewSize * 2.0 - 1.0, 0.0, 1.0);
      out.pointSize = extent;
      out.streak = streak / extent;
      out.radius = pixels / extent * 0.5;
      // A streak spreads the same flake over more pixels, so each is fainter.
      out.alpha = s.alpha * min(pixels / 2.0, 1.0) * pixels / max(pixels + length(streak) * 0.6, 0.001);
      out.soft = s.soft;
      out.tint = float4(s.tintRed, s.tintGreen, s.tintBlue, s.tintAmount);
      out.light = u.light.rgb;
      out.lump = s.lump;
      out.spin = s.lump > 0.0 ? u.time * (s.lump - 0.5) * 9.0 + s.lump * 40.0 : 0.0;
      out.leaf = 0.0;
      return out;
  }

  fragment float4 spriteFragment(SpriteOut in [[stage_in]], float2 coord [[point_coord]], constant Uniforms &u [[buffer(1)]]) {
      // Point coordinates run down the screen; velocities run up.
      float2 p = float2(coord.x - 0.5, 0.5 - coord.y);
      if (in.leaf != 0.0) {
          // The leaf over the exposure, from where it was to where it is now, turning and tumbling on the way.
          int n = int(in.samples);
          float4 sum = float4(0.0);
          for (int k = 0; k < n; k++) {
              float along = (float(k) + 0.5) / float(n) - 0.5;
              float back = along - 0.5;
              sum += botanicalAt(p * in.reach - in.streak * along, in.leaf, in.turn + in.turnSmear * back,
                            clamp(in.flip + in.flipSmear * back, -1.0, 1.0), in.alpha, in.light,u.autumn);
          }
          sum /= float(n);
          if (sum.a < 0.002) discard_fragment();
          return sum;
      }

      float2 half_ = in.streak * 0.5;
      float span = dot(half_, half_);
      float t = span > 0.0 ? clamp(dot(p, half_) / span, -1.0, 1.0) : 0.0;
      float2 d = p - half_ * t;
      float r = length(d) / max(in.radius, 0.001);
      float shading = 0.0;
      if (in.lump > 0.0) {
          float angle = atan2(d.y, d.x) + in.spin;
          r /= 1.0 + 0.14 * sin(3.0 * angle) + 0.08 * sin(5.0 * angle + in.lump * 21.0) + 0.05 * sin(2.0 * angle + in.lump * 9.0);
          shading = saturate(dot(d / max(in.radius, 0.001), float2(0.45, -0.6))) * 0.4;
      }
      // Brighter at the head, where the flake is now, than at the tail, where it was.
      float head = span > 0.0 ? 0.15 + 0.85 * pow(t * 0.5 + 0.5, 1.5) : 1.0;
      float a = (1.0 - smoothstep(mix(0.6, 0.0, in.soft), 1.0, r)) * in.alpha * head;
      if (a < 0.002) discard_fragment();
      float3 core = float3(0.965, 0.975, 0.995);
      float3 rim = float3(0.62, 0.67, 0.77);
      float3 color = mix(core, rim, saturate(smoothstep(0.35, 1.0, r) * 0.65 + shading));
      color = mix(color, in.tint.rgb, in.tint.a) * in.light;
      return float4(color * a, a);
  }

  struct PileOut {
      float4 position [[position]];
      float2 point;
  };

  vertex PileOut pileVertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
      float2 corner = float2(float(vid & 1), float(vid >> 1));
      float2 p = float2(corner.x * float(u.columnCount) * u.columnWidth, mix(u.pileBottom, u.pileTop, corner.y));
      PileOut out;
      out.position = float4((p + u.origin + u.shake.xy) / u.viewSize * 2.0 - 1.0, 0.0, 1.0);
      out.point = p;
      return out;
  }

  static float heightAt(const device float *h, constant Uniforms &u, float x) {
      float f = x / u.columnWidth - 0.5;
      float base = floor(f);
      int i = clamp(int(base), 0, u.columnCount - 1);
      int j = min(i + 1, u.columnCount - 1);
      return mix(h[i], h[j], saturate(f - base));
  }

  fragment float4 pileFragment(PileOut in [[stage_in]],
                               const device float *heights [[buffer(0)]],
                               constant Uniforms &u [[buffer(1)]],
                               constant float4 *occluders [[buffer(2)]]) {
      float2 world = in.point + u.origin;
      for (int k = 0; k < u.occluderCount; k++) {
          float4 o = occluders[k];
          if (world.x >= o.x && world.x < o.z && world.y >= o.y && world.y < o.w) discard_fragment();
      }

      float x = in.point.x;
      // Where along the heap itself: it stays put as the window's left edge is dragged under it.
      float2 grain = float2(x - u.shake.z, in.point.y);
      float level = heightAt(heights, u, x);
      float bed = heightAt(heights + u.columnCount, u, x);
      // The leaves on top are drawn one by one, the heap under them as a mass with a ragged top; a leaf or two lie on their own.
      if (u.autumn > 0.5) {
          level -= 2.5;
          level += (noise(grain.x * 0.4) - 0.5) * 2.4 * saturate((level - bed) / 4.0);
      }
      float depth = level - in.point.y;
      float coverage = saturate(depth * u.scale + 0.5)
          * saturate((in.point.y - bed) * u.scale + 0.5)
          * saturate((level - bed) / 0.75);
      if (coverage <= 0.0) discard_fragment();

      float slope = (heightAt(heights, u, x + 2.0) - heightAt(heights, u, x - 2.0)) * 0.25;
      float light = dot(normalize(float2(-slope, 1.0)), normalize(float2(-0.5, 1.0)));

      float3 color;
      if (u.autumn > 0.5) {
          // Deeper in the heap the leaves lie in shadow.
          color = botanicalLitter(grain,u.autumn);
          color = mix(color, color * float3(0.62, 0.54, 0.5), saturate(1.0 - exp(-depth / 18.0)) * 0.6);
          color *= 0.84 + 0.2 * light;
      } else {
          float3 shadow = mix(float3(0.72, 0.78, 0.88), u.shadowTint.rgb, u.shadowTint.a);
          float3 surface = mix(float3(0.925, 0.94, 0.965), min(u.shadowTint.rgb * 1.18, float3(1.0)), u.shadowTint.a * 0.2);
          float shade = (1.0 - exp(-depth / 30.0)) * 0.32 + (1.0 - light) * 0.6 * exp(-depth / 5.0);
          color = mix(surface, shadow, saturate(shade));
          color = mix(color, float3(0.975, 0.982, 0.995), exp(-depth * 0.9) * 0.6);
          color += (hash(floor(in.position.xy)) - 0.5) * 0.02;

          float seed = hash(floor(in.position.xy * 0.5) + 31.7);
          if (seed > 0.992) {
              float twinkle = pow(saturate(sin(u.time * (0.6 + seed * 1.8) + seed * 90.0)), 28.0);
              color = mix(color, float3(1.0), twinkle * exp(-depth / 7.0));
          }
      }

      // Night dims fallen leaves without draining their colour.
      color *= u.autumn > 0.5 ? mix(float3(1.0), u.light.rgb, 0.4) : u.light.rgb;
      color = mix(color, u.rim.rgb, u.rim.a * exp(-depth / 2.5) * (1.0 - min(1.0,u.autumn)));
      return float4(color * coverage, coverage);
  }

  """
