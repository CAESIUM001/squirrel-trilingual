#include "rime_api.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <unistd.h>
#include <time.h>

static void js(const char *s) {
  putchar('"');
  if (s) for (const unsigned char *p=(const unsigned char*)s; *p; ++p) {
    if (*p=='"' || *p=='\\') { putchar('\\'); putchar(*p); }
    else if (*p=='\n') fputs("\\n",stdout);
    else if (*p=='\r') fputs("\\r",stdout);
    else if (*p=='\t') fputs("\\t",stdout);
    else if (*p<32) printf("\\u%04x",*p);
    else putchar(*p);
  }
  putchar('"');
}
static double now_ms(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts); return ts.tv_sec*1000.0+ts.tv_nsec/1000000.0; }
static void dump(RimeApi *api,RimeSessionId session,const char *action,int handled,double started) {
  fputs("{\"action\":",stdout);js(action);printf(",\"handled\":%d,\"input\":",handled);js(api->get_input(session));
  RIME_STRUCT(RimeContext, ctx);
  if (api->get_context(session,&ctx)) {
    fputs(",\"preedit\":",stdout);js(ctx.composition.preedit);
    printf(",\"page_size\":%d,\"page\":%d,\"highlighted\":%d,\"candidates\":[",ctx.menu.page_size,ctx.menu.page_no,ctx.menu.highlighted_candidate_index);
    for (int i=0;i<ctx.menu.num_candidates;++i) {
      if(i)putchar(',');fputs("{\"text\":",stdout);js(ctx.menu.candidates[i].text);fputs(",\"comment\":",stdout);js(ctx.menu.candidates[i].comment);putchar('}');
    }
    putchar(']');api->free_context(&ctx);
  }
  RIME_STRUCT(RimeCommit, commit);
  if (api->get_commit(session,&commit)) {fputs(",\"commit\":",stdout);js(commit.text);api->free_commit(&commit);}
  RIME_STRUCT(RimeStatus, status);
  if(api->get_status(session,&status)) {fputs(",\"schema\":",stdout);js(status.schema_id);printf(",\"ascii\":%s",status.is_ascii_mode?"true":"false");api->free_status(&status);}
  printf(",\"elapsed_ms\":%.3f}\n",now_ms()-started);fflush(stdout);
}
int main(int argc,char **argv) {
  if(argc<4) {fprintf(stderr,"usage: probe USER_DIR SHARED_DIR SCHEMA [input:KEY_SEQUENCE|key:CODE:MASK|option:NAME:VALUE|clear|page:forward|page:back|show] ...\n");return 2;}
  char resolved[PATH_MAX];
  if(!realpath(argv[1],resolved)||!strstr(resolved,"/work/")) {fprintf(stderr,"Refusing a user directory outside isolated /work/.\n");return 2;}
  const char *framework=getenv("RIME_PROBE_FRAMEWORKS");
  if(!framework){fprintf(stderr,"Set RIME_PROBE_FRAMEWORKS to the Squirrel Frameworks directory.\n");return 2;}
  char path[PATH_MAX];snprintf(path,sizeof(path),"%s/librime.1.dylib",framework);
  void *handle=dlopen(path,RTLD_NOW|RTLD_GLOBAL);if(!handle){fprintf(stderr,"%s\n",dlerror());return 2;}
  snprintf(path,sizeof(path),"%s/rime-plugins/librime-lua.dylib",framework);
  if(!dlopen(path,RTLD_NOW|RTLD_GLOBAL)){fprintf(stderr,"%s\n",dlerror());return 2;}
  RimeApi *(*get_api)(void)=dlsym(handle,"rime_get_api");RimeApi *api=get_api();
  const char *modules[]={"default","lua",NULL};
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir=argv[2];traits.user_data_dir=resolved;traits.app_name="rime.plugin-probe";traits.distribution_name="Plugin probe";traits.distribution_code_name="squirrel";traits.distribution_version="1";traits.modules=modules;traits.log_dir="";traits.min_log_level=2;
  double initial_started=now_ms();
  api->setup(&traits);api->initialize(&traits);
  RimeSessionId session=api->create_session();
  if(!session||!api->select_schema(session,argv[3])) {fprintf(stderr,"Cannot create session/select schema\n");api->finalize();return 3;}
  fprintf(stderr,"librime %s, isolated user dir %s\n",api->get_version(),resolved);
  dump(api,session,"initial",1,initial_started);
  for(int i=4;i<argc;++i) {
    char *a=argv[i];int handled=1;double started=now_ms();
    if(!strncmp(a,"input:",6)) handled=api->simulate_key_sequence(session,a+6);
    else if(!strncmp(a,"key:",4)) {int code,mask;if(sscanf(a+4,"%i:%i",&code,&mask)!=2)return 2;handled=api->process_key(session,code,mask);}
    else if(!strncmp(a,"option:",7)) {char *v=strrchr(a+7,':');if(!v)return 2;*v=0;api->set_option(session,a+7,atoi(v+1));*v=':';}
    else if(!strncmp(a,"caret:",6))api->set_caret_pos(session,(size_t)atoi(a+6));
    else if(!strcmp(a,"clear"))api->clear_composition(session);
    else if(!strcmp(a,"page:forward"))handled=api->change_page(session,False);
    else if(!strcmp(a,"page:back"))handled=api->change_page(session,True);
    else if(!strcmp(a,"commit"))handled=api->commit_composition(session);
    else if(strcmp(a,"show")) {fprintf(stderr,"Unknown action: %s\n",a);return 2;}
    dump(api,session,a,handled,started);
  }
  api->destroy_session(session);api->finalize();return 0;
}
