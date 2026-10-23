/* Synthetic instruction fixtures exercise the production export/device paths without game data. */
#include "../games/totk/runtime/game_patches_v143.c"
#include <sys/mman.h>
#define CHECK(x) do { if(!(x)){fprintf(stderr,"line %d: %s\n",__LINE__,#x);return 1;} } while(0)
_Noreturn void runtime_fail(const char *message){fprintf(stderr,"refused: %s\n",message);exit(78);}
void *runtime_symbol(const char *name){(void)name;return NULL;}
void runtime_survey_init(Module *module){(void)module;}
uint64_t runtime_now_ns(void){return 1;}
void runtime_oe_push_message(uint32_t message){(void)message;}
int mfxup_output_enabled(void){return 0;}
void dm_gfx_set_flag(const char *name,int value){(void)name;(void)value;}
static void word(Module *m,uint64_t offset,uint32_t value){memcpy(m->base+offset,&value,4);}
int main(int argc,char **argv){
    CHECK(argc==2);
    int baseline=!strcmp(argv[1],"baseline");
    setenv("TOTK_EXPORT_IOS","synthetic",1);setenv("TOTK_IOS_DISPLAY_SETTINGS","1",1);
    setenv("TOTK_OUTPUT_RES",baseline?"1280x720":"1440x1080",1);
    setenv("TOTK_RENDER_RES",baseline?"1280x720":"1440x1080",1);
    setenv("TOTK_ASPECT",baseline?"0":"display",1);
    unsetenv("TOTK_ASPECT_VERT");
    if(!strcmp(argv[1],"stock")){
        unsetenv("TOTK_IOS_DISPLAY_SETTINGS");setenv("TOTK_OUTPUT_RES","0",1);setenv("TOTK_RENDER_RES","0",1);
    }
    if(!strcmp(argv[1],"oversize_scene"))setenv("TOTK_RENDER_RES","2000x1080",1);
    if(!strcmp(argv[1],"oversize"))setenv("TOTK_OUTPUT_RES","2000x1080",1);
    Module m={.name="main",.text_end=0xc00100,.file_size=0xc08000,.size=0xc0c000};
    m.base=mmap(NULL,m.size,PROT_READ|PROT_WRITE,MAP_ANON|MAP_PRIVATE,-1,0);
    CHECK(m.base!=MAP_FAILED);
    uint64_t data=0xc08000,stub=0xc00100;
    static const uint64_t projection[]={0x100,0x200};
    const uint32_t original=0x1e211800;
#if TARGET_OS_IPHONE && defined(TOTK_IOS_DISPLAY_SETTINGS)
    word(&m,0xbdb578,0xd2800008|(1920<<5));word(&m,0xbdb584,0xf2c00008|(1080<<5));
    word(&m,0x3dcb28,branch(0x3dcb28,stub+16));
    uint32_t output[]={adrp(9,(uintptr_t)m.base+stub+16,(uintptr_t)m.base+data),
        0xf9001533,0xf9401123,0xf9000a63,0xd360fc64,0xf9028663,branch(stub+40,0x3dcb30)};
    memcpy(m.base+stub+16,output,sizeof output);
    word(&m,0x585e48,adrp(3,(uintptr_t)m.base+0x585e48,(uintptr_t)m.base+data));
    word(&m,0x585e50,0x2d420460);word(&m,0x585e54,0xbd0cc660);word(&m,0x585e60,0xbd0cca61);
    word(&m,0x5848a8,0x52a7f009);
    for(unsigned i=0;i<2;i++){
        uint32_t code[8];uint64_t at=stub+48+ASPECT_STUB*i;
        CHECK(!aspect_stub(original,at,projection[i],data,code));
        memcpy(m.base+at,code,sizeof code);word(&m,projection[i],aspect_b(projection[i],at));
    }
#else
    word(&m,0xbdb578,0xd280f008);word(&m,0xbdb584,0xf2c08708);
    word(&m,0x3dcb28,0xd360fc64);word(&m,0x3dcb2c,0xf9028663);word(&m,0x3dcb30,0xd001ac08);
    word(&m,0x585e48,0x1e220160);word(&m,0x585e50,0xbd0cc660);word(&m,0x585e54,0x1e220140);word(&m,0x585e60,0xbd0cca60);
    word(&m,0x5848a8,0x2a1703e9);
    for(unsigned i=0;i<2;i++)word(&m,projection[i],original);
#endif
    if(!strcmp(argv[1],"bad_output"))word(&m,0xbdb578,0);
    if(!strcmp(argv[1],"bad_render"))word(&m,0x585e50,0);
    if(!strcmp(argv[1],"bad_fixed"))word(&m,0x5848a8,0);
    if(!strcmp(argv[1],"bad_aspect"))word(&m,projection[0],0);
#if TARGET_OS_IPHONE
    // A device must validate signed text, never modify it.
    CHECK(!mprotect(m.base,data,PROT_READ));
#endif
    if(!strcmp(argv[1],"stock")){
        unsigned w,h;CHECK(!runtime_output_res(&w,&h));CHECK(!runtime_render_res(&w,&h));
        CHECK(!runtime_output_res_extra_bytes());
        patch_output_res(&m);patch_render_res(&m);patch_fixed_res(&m);
        aspect_install(&m,"synthetic",projection,2,0,stub+48,0,data);
        CHECK(!runtime_aspect_now());puts("display profile pass");return 0;
    }
    runtime_aspect_view(1440,1080);
    patch_output_res(&m);patch_render_res(&m);patch_fixed_res(&m);
    aspect_install(&m,"synthetic",projection,2,0,stub+48,0,data);
    uint64_t expected=baseline?pack_size(1280,720):pack_size(1440,1080);
    CHECK(runtime_output_size_current()==expected);
    unsigned w=0,h=0;CHECK(runtime_output_res(&w,&h)&&w==1920&&h==1080);
    CHECK(runtime_render_res(&w,&h)&&w==1920&&h==1080);
    CHECK(runtime_output_res_extra_bytes()>0&&runtime_output_res_extra_bytes()<100*1024*1024);
    float scene[2];memcpy(scene,m.base+data+16,sizeof scene);
    CHECK(scene[0]==(baseline?1280:1440)&&scene[1]==(baseline?720:1080));
    CHECK(baseline?runtime_aspect_now()==0:fabsf(runtime_aspect_now()-4.0f/3.0f)<0.00001f);
    CHECK(!munmap(m.base,m.size));
    puts("display profile pass");return 0;
}
