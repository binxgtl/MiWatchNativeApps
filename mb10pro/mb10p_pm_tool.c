/*
 * mb10p_pm_tool.c -- package-manager inspector / remover for fw 3.201.026.
 *
 * ONE source, TWO builds (see build_mb10p.sh):
 *
 *   -DPM_TOOL_INSPECT   mb10p_pm_inspect.elf   READ-ONLY. Safe to rmmod when done.
 *   -DPM_TOOL_REMOVE    mb10p_pm_remove.elf    EXPERIMENTAL. Never shipped in a
 *                                              watchface; not hardware-tested.
 *
 * Neither build registers anything with the package manager or the launcher
 * and neither leaves a pointer to its own memory in the system, so both can be
 * rmmod'ed once they have logged "DONE" (the destructor logs LOG_ERR if not).
 *
 * Everything here runs from an LVGL timer (LVGL thread), never from the shell
 * thread that executes insmod, same rule as mb10p_app_safe.c.
 *
 * Layout facts used (miwear_app_v2_t = 0x40-byte node copied to the heap by
 * the firmware's install(); page structs are NOT copied, the node's page
 * array at +0x30 holds pointers to the module's own page structs):
 *   node +0x00/+0x04 list links   +0x08 name*   +0x0C icon*   +0x10 app_id
 *   node +0x12 flags (bit 0x08 clear => "recoverable", kept after unregister)
 *   node +0x1C,0x20,0x24,0x28,0x38 callbacks (point into the app module!)
 *   node +0x30 pages* : u16 count @0, then pointers at 8 + 4*i
 *   page +0x14 page_id +0x16 app_id +0x18 flags +0x24 async_destroy
 *        +0x28 lifecycle_state +0x30 root_object +0x40/0x44 registry links
 *
 * Log grammar (parsed by wf_native_manager; keep stable):
 *   [pm_inspect] BEGIN id=0x%x period_ms=%u ticks=%u
 *   [pm_inspect] NODE seq=%u node=0x%08x flags=0x%04x name=0x%08x icon=0x%08x
 *                cb1c=0x%08x cb20=0x%08x cb24=0x%08x cb28=0x%08x cb38=0x%08x
 *                pages=0x%08x unin=0x%08x
 *   [pm_inspect] PAGE seq=%u i=%u page=0x%08x pid=%u state=%u layer=%u
 *                kind=%u adestroy=0x%x root=0x%08x prev=0x%08x next=0x%08x
 *   [pm_inspect] NONE seq=%u unin=0x%08x          (app not in the main list)
 *   [pm_inspect] DONE seq=%u
 */

#include <stdint.h>
#include "common/nuttx/syslog.h"
#include "platform/miwear_system.h"
#include "common/miwear/app.h"

#if defined(PM_TOOL_INSPECT) == defined(PM_TOOL_REMOVE)
#  error "define exactly one of PM_TOOL_INSPECT / PM_TOOL_REMOVE"
#endif
#if !defined(MB10P_FW_VERSION) || (MB10P_FW_VERSION != 3201026)
#  error "mb10p_pm_tool is only ported for fw 3.201.026"
#endif

#ifndef PM_TOOL_APP_ID
#  define PM_TOOL_APP_ID  0xC1u          /* mb10p_app_safe CALC_APP_ID */
#endif

#ifdef PM_TOOL_INSPECT
#  define TAG "[pm_inspect]"
#  ifndef PM_TOOL_PERIOD_MS
#    define PM_TOOL_PERIOD_MS 1000u
#  endif
#  ifndef PM_TOOL_TICKS
#    define PM_TOOL_TICKS 90u            /* ~90 s: time to open/close the app */
#  endif
#else
#  define TAG "[pm_remove]"
#  ifndef PM_TOOL_PAGE_IDLE
#    define PM_TOOL_PAGE_IDLE 0xFFFFu    /* unknown until the inspector shows it */
#  endif
#endif

static void *g_timer;
static volatile unsigned g_seq;
static volatile int g_done;

/* ---- raw readers --------------------------------------------------------- */
__attribute__((unused)) static int plausible(uint32_t p)
{
    return p >= 0x20000000u && p < 0x40000000u && (p & 3u) == 0;
}
__attribute__((unused)) static uint32_t rd32(uint32_t base, uint32_t off) { return *(volatile uint32_t *)(base + off); }
__attribute__((unused)) static uint32_t rd16(uint32_t base, uint32_t off) { return *(volatile uint16_t *)(base + off); }
__attribute__((unused)) static uint32_t rd8 (uint32_t base, uint32_t off) { return *(volatile uint8_t  *)(base + off); }

/* Fixed-offset 32-bit read: the offset must be 4-aligned (bases are checked by
 * plausible()), so no LDR can be unaligned. Checked at compile time. */
#define RD32C(base, off) (__extension__({ \
    _Static_assert(((off) & 3u) == 0, "32-bit field offset " #off " is not 4-aligned"); \
    rd32((base), (off)); }))

#define PAGES_MAX 8u

#ifdef PM_TOOL_INSPECT
static uint32_t g_prev_sig;

static uint32_t sig_mix(uint32_t h, uint32_t v) { return (h ^ v) * 16777619u; }

static void snapshot(int force)
{
    uint32_t node  = (uint32_t)app_lookup(PM_TOOL_APP_ID);
    uint32_t unin  = (uint32_t)pm_uninstalled_lookup(PM_TOOL_APP_ID);
    uint32_t sig   = 2166136261u;
    sig = sig_mix(sig, node);
    sig = sig_mix(sig, unin);

    if (!node) {
        if (force || sig != g_prev_sig)
            syslog(LOG_WARN, TAG " NONE seq=%u unin=0x%08x\n", g_seq, unin);
        g_prev_sig = sig;
        return;
    }
    if (!plausible(node)) {
        syslog(LOG_ERR, TAG " BAD node=0x%08x\n", node);
        return;
    }
    uint32_t pages = RD32C(node, 0x30);
    uint32_t cnt   = plausible(pages) ? rd16(pages, 0) : 0;
    if (cnt > PAGES_MAX) cnt = PAGES_MAX;

    /* +0x12 is the u16 flags field: read it as 16 bits. (A 32-bit read there was
     * unaligned and also mixed in the two bytes at +0x14.) */
    sig = sig_mix(sig, rd16(node, 0x12));
    sig = sig_mix(sig, RD32C(node, 0x1C));
    sig = sig_mix(sig, RD32C(node, 0x20));
    sig = sig_mix(sig, RD32C(node, 0x24));
    sig = sig_mix(sig, RD32C(node, 0x28));
    sig = sig_mix(sig, RD32C(node, 0x38));
    sig = sig_mix(sig, pages);
    for (uint32_t i = 0; i < cnt; i++) {
        uint32_t pg = rd32(pages, 8 + 4 * i);
        if (!plausible(pg)) continue;
        sig = sig_mix(sig, rd8(pg, 0x28));
        sig = sig_mix(sig, RD32C(pg, 0x24));
        sig = sig_mix(sig, RD32C(pg, 0x30));
        sig = sig_mix(sig, RD32C(pg, 0x40));
        sig = sig_mix(sig, RD32C(pg, 0x44));
    }
    if (!force && sig == g_prev_sig)
        return;                          /* log only on change */
    g_prev_sig = sig;

    syslog(LOG_WARN, TAG " NODE seq=%u node=0x%08x flags=0x%04x name=0x%08x icon=0x%08x "
           "cb1c=0x%08x cb20=0x%08x cb24=0x%08x cb28=0x%08x cb38=0x%08x pages=0x%08x unin=0x%08x\n",
           g_seq, node, rd16(node, 0x12), RD32C(node, 0x08), RD32C(node, 0x0C),
           RD32C(node, 0x1C), RD32C(node, 0x20), RD32C(node, 0x24), RD32C(node, 0x28),
           RD32C(node, 0x38), pages, unin);
    for (uint32_t i = 0; i < cnt; i++) {
        uint32_t pg = rd32(pages, 8 + 4 * i);
        if (!plausible(pg)) {
            syslog(LOG_WARN, TAG " PAGE seq=%u i=%u page=0x%08x implausible\n", g_seq, i, pg);
            continue;
        }
        syslog(LOG_WARN, TAG " PAGE seq=%u i=%u page=0x%08x pid=%u state=%u layer=%u kind=%u "
               "adestroy=0x%x root=0x%08x prev=0x%08x next=0x%08x\n",
               g_seq, i, pg, rd16(pg, 0x14), rd8(pg, 0x28), rd8(pg, 0x29), rd8(pg, 0x2A),
               RD32C(pg, 0x24), RD32C(pg, 0x30), RD32C(pg, 0x40), RD32C(pg, 0x44));
    }
}

static void tool_tick(lv_timer_t *t)
{
    (void)t;
    g_seq++;
    snapshot(g_seq <= 2);                /* always log the first two ticks */
    if (g_seq >= PM_TOOL_TICKS) {
        lv_timer_delete(g_timer);
        g_timer = 0;
        g_done = 1;
        syslog(LOG_WARN, TAG " DONE seq=%u\n", g_seq);
    }
}
#endif /* PM_TOOL_INSPECT */

#ifdef PM_TOOL_REMOVE
/* EXPERIMENTAL one-shot removal of the registered app. Refuses (and logs why)
 * unless every precondition holds. Not hardware-tested. */
typedef int (*pm_unregister_t)(miwear_app_t *app);

static void refuse(const char *why)
{
    syslog(LOG_ERR, TAG " REFUSED reason=%s\n", why);
}

static void tool_tick(lv_timer_t *t)
{
    (void)t;
    lv_timer_delete(g_timer);
    g_timer = 0;
    g_done = 1;

    uint32_t node = (uint32_t)app_lookup(PM_TOOL_APP_ID);
    if (!node) { syslog(LOG_WARN, TAG " NOT_REGISTERED id=0x%x\n", PM_TOOL_APP_ID); return; }
    if (!plausible(node)) { refuse("node_implausible"); return; }

    uint32_t flags = rd16(node, 0x12);
    if (!(flags & 0x08u)) {
        /* "recoverable": unregister keeps the node AND its page array (which
         * points at the app module's page structs) in the uninstalled list. */
        refuse("recoverable_app_reboot_required");
        return;
    }
    uint32_t pages = rd32(node, 0x30);
    if (!plausible(pages)) { refuse("pages_implausible"); return; }
    uint32_t cnt = rd16(pages, 0);
    if (cnt > PAGES_MAX) { refuse("pages_count"); return; }
#if PM_TOOL_PAGE_IDLE == 0xFFFFu
    refuse("page_idle_state_unknown_run_inspector_first");
    return;
#else
    for (uint32_t i = 0; i < cnt; i++) {
        uint32_t pg = rd32(pages, 8 + 4 * i);
        if (!plausible(pg) || rd8(pg, 0x28) != PM_TOOL_PAGE_IDLE) {
            refuse("page_not_idle");
            return;
        }
    }
    syslog(LOG_WARN, TAG " STEP launcher_del id=0x%x\n", PM_TOOL_APP_ID);
    app_launcher_del(PM_TOOL_APP_ID);

    syslog(LOG_WARN, TAG " STEP neutralize_callbacks node=0x%08x\n", node);
    *(volatile uint32_t *)(node + 0x1C) = 0;
    *(volatile uint32_t *)(node + 0x20) = 0;
    *(volatile uint32_t *)(node + 0x24) = 0;
    *(volatile uint32_t *)(node + 0x28) = 0;
    *(volatile uint32_t *)(node + 0x38) = 0;

    syslog(LOG_WARN, TAG " STEP unregister\n");
    int rc = g_packagemanager_api->unregister((miwear_app_t *)node);   /* frees node: do not touch it again */

    uint32_t still  = (uint32_t)app_lookup(PM_TOOL_APP_ID);
    uint32_t unin   = (uint32_t)pm_uninstalled_lookup(PM_TOOL_APP_ID);
    syslog(LOG_WARN, TAG " RESULT rc=%d main_list=0x%08x uninstalled_list=0x%08x clean=%d\n",
           rc, still, unin, (still == 0 && unin == 0));
#endif
}
#endif /* PM_TOOL_REMOVE */

/* ---- module entry / exit -------------------------------------------------- */
__attribute__((constructor)) int module_initialize(void)
{
#ifdef PM_TOOL_INSPECT
    syslog(LOG_WARN, TAG " BEGIN id=0x%x period_ms=%u ticks=%u\n",
           PM_TOOL_APP_ID, PM_TOOL_PERIOD_MS, PM_TOOL_TICKS);
    g_timer = lv_timer_create(tool_tick, PM_TOOL_PERIOD_MS, 0);
#else
    syslog(LOG_WARN, TAG " BEGIN id=0x%x (experimental)\n", PM_TOOL_APP_ID);
    g_timer = lv_timer_create(tool_tick, 500, 0);
#endif
    if (!g_timer) { g_done = 1; syslog(LOG_ERR, TAG " lv_timer_create failed\n"); }
    return 0;
}

__attribute__((destructor, used)) static void module_uninitialize(void)
{
    if (g_timer)
        syslog(LOG_ERR, TAG " rmmod while timer pending; reboot now\n");
    else
        syslog(LOG_WARN, TAG " unloaded done=%d\n", g_done);
}
