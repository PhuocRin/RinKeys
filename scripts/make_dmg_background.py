# Vẽ nền cửa sổ cài đặt .dmg (assets/dmg-background.png và @2x).
# Cách chạy: python3 scripts/make_dmg_background.py assets/dmg-background.png assets/dmg-background@2x.png
# Cần Pillow và font Inter (đổi đường dẫn FONT bên dưới nếu máy để chỗ khác).
# Nền cao 470 nhưng nội dung nằm trong 400 phía trên, để Finder có bật thanh đường dẫn / thanh trạng thái vẫn không che chữ.
from PIL import Image, ImageDraw, ImageFilter, ImageFont
import sys
W,H=600,470
FONT="/usr/share/fonts/opentype/inter/"
def make(s,out):
    w,h=W*s,H*s
    img=Image.new("RGB",(w,h))
    # vertical gradient
    top=(236,241,250); bot=(222,228,244)
    px=img.load()
    for y in range(h):
        t=y/(h-1)
        c=tuple(int(top[i]*(1-t)+bot[i]*t) for i in range(3))
        for x in range(w): px[x,y]=c
    # colour blobs
    blobs=Image.new("RGBA",(w,h),(0,0,0,0))
    d=ImageDraw.Draw(blobs)
    for (cx,cy,r,col) in [(90,70,170,(120,170,255,150)),(520,90,160,(190,140,255,130)),
                          (470,370,190,(110,220,230,120)),(110,380,150,(255,170,210,90))]:
        d.ellipse([(cx-r)*s,(cy-r)*s,(cx+r)*s,(cy+r)*s],fill=col)
    blobs=blobs.filter(ImageFilter.GaussianBlur(70*s))
    img=Image.alpha_composite(img.convert("RGBA"),blobs)

    def glass(box,radius,alpha=120,blur=18):
        x0,y0,x1,y1=[v*s for v in box]
        # shadow
        sh=Image.new("RGBA",img.size,(0,0,0,0))
        ImageDraw.Draw(sh).rounded_rectangle([x0,y0+6*s,x1,y1+6*s],radius*s,fill=(60,70,110,40))
        sh=sh.filter(ImageFilter.GaussianBlur(14*s))
        base=Image.alpha_composite(img,sh)
        # frosted: blur region
        region=base.crop((x0,y0,x1,y1)).filter(ImageFilter.GaussianBlur(blur*s))
        mask=Image.new("L",(x1-x0,y1-y0),0)
        ImageDraw.Draw(mask).rounded_rectangle([0,0,x1-x0-1,y1-y0-1],radius*s,fill=255)
        base.paste(region,(x0,y0),mask)
        ov=Image.new("RGBA",img.size,(0,0,0,0))
        od=ImageDraw.Draw(ov)
        od.rounded_rectangle([x0,y0,x1,y1],radius*s,fill=(255,255,255,alpha))
        # top highlight
        hl=Image.new("RGBA",img.size,(0,0,0,0))
        hd=ImageDraw.Draw(hl)
        hd.rounded_rectangle([x0,y0,x1,y0+(y1-y0)//2],radius*s,fill=(255,255,255,45))
        hl=hl.filter(ImageFilter.GaussianBlur(6*s))
        od.rounded_rectangle([x0,y0,x1,y1],radius*s,outline=(255,255,255,210),width=max(1,int(1.5*s)))
        base=Image.alpha_composite(base,ov)
        return base

    # slots behind icons (icon centers 150,180 and 450,180)
    img=glass((75,105,225,275),34)
    img=glass((375,105,525,275),34)
    # arrow pill
    img=glass((250,160,350,200),20,alpha=140,blur=10)
    d=ImageDraw.Draw(img)
    # arrow
    ax0,ax1,ay=268*s,330*s,180*s
    col=(70,95,170,235)
    d.line([ax0,ay,ax1-6*s,ay],fill=col,width=int(4*s))
    d.polygon([(ax1+2*s,ay),(ax1-12*s,ay-10*s),(ax1-12*s,ay+10*s)],fill=col)
    # text
    ft=ImageFont.truetype(FONT+"InterDisplay-Bold.otf",30*s)
    fs=ImageFont.truetype(FONT+"Inter-Medium.otf",14*s)
    def ctext(y,txt,f,fill):
        tw=d.textlength(txt,font=f); d.text(((w-tw)/2,y*s),txt,font=f,fill=fill)
    ctext(30,"RinKeys",ft,(28,34,60,255))
    ctext(70,"Kéo RinKeys vào Applications để cài đặt",fs,(70,80,110,255))
    fx=ImageFont.truetype(FONT+"Inter-SemiBold.otf",12*s)
    fy=ImageFont.truetype(FONT+"Inter-Medium.otf",11*s)
    ctext(304,"Mở lần đầu bị chặn? Bấm Xong, ĐỪNG bấm Chuyển vào Thùng rác.",fx,(40,46,80,255))
    ctext(322,"Vào Cài đặt → Quyền riêng tư & Bảo mật → kéo xuống phần Bảo mật → Vẫn mở",fx,(40,46,80,255))
    ctext(346,"Blocked? Click Done (not Move to Trash) → Settings → Privacy & Security → Security → Open Anyway",fy,(75,85,120,255))
    img.convert("RGB").save(out)
make(1,sys.argv[1]); make(2,sys.argv[2])
