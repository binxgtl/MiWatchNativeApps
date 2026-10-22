/*
 * mb10p_app_safe.c -- lifecycle-test variant of mb10p_app.c.
 *
 * Differences from mb10p_app.c:
 *   - Does NOT read, delete or reset the current watchface
 *     (no g_watchface_config / watchface_manager_* calls at all).
 *   - The "done" notification is OFF by default (it adds an entry to the
 *     system notification list). Build with -DCALC_NOTIFY_ON_INSTALL to
 *     restore it.
 *   - Logs every lifecycle step and the registration state, and warns in
 *     the destructor when the app is still registered.
 *
 * Lifecycle rules (from the fw_3.201.026 loader, see report):
 *   - insmod runs .init_array -> module_initialize (shell thread).
 *   - Registration is deferred to the LVGL thread via a one-shot timer
 *     (500 ms). Do not rmmod before the "timer fired" log line.
 *   - rmmod runs .fini_array and then FREES the module's text/data. Once the
 *     app is registered, the package manager keeps pointers into that
 *     memory, so rmmod after registration is a use-after-free.
 *     Remove the app by rebooting instead (modules are not reloaded on boot).
 *
 *     insmod /data/mb10p_app_safe.elf calc_safe
 */

#include <stdint.h>
#include "common/misc/mem.h"
#include "common/nuttx/syslog.h"
#include "platform/miwear_system.h"
#include "common/miwear/app.h"
#include "common/lvgl/control.h"
#include "ui/calc_page.h"

#define LOG_TAG        "[calc_safe]"
#define APP_TAG        "com.m0tral.calculator"

#define CALC_APP_ID    0xC1u
#define CALC_PAGE_ID   0x00u
#define APP_NAME       APP_TAG

/* miwear_app_v2_t.flags. 0 = what the hardware-tested build uses.
 * Bit 0x08 clear => the package manager treats the app as "recoverable": on
 * unregister it keeps the node (with the callback pointers) and its page array
 * (with pointers to THIS module's page struct) in the uninstalled list, so the
 * module could never be freed safely. Bit 0x08 set => unregister frees both.
 * Only the experimental build (-DCALC_APP_FLAGS=0x08, see build_mb10p.sh and
 * docs/mb10p-3.201.026/LIFECYCLE_AND_REBOOT.md) sets it; NOT hardware-tested. */
#ifndef CALC_APP_FLAGS
#  define CALC_APP_FLAGS 0
#endif
#define PAGE_NAME      "main"

__attribute__((used)) static void *post_timer_id;
static volatile int g_registered;     /* 1 once pm install returned 0 */

/* ---- Calculator app descriptor ------------------------------------------- */
static char *calc_app_get_name(void)
{
    return "Calculator";
}

static int calc_page_on_signal(void *page, lv_obj_t* root, void *data)
{
    (void)page; (void)root; (void)data;
    syslog(LOG_WARN, "%s page main on_signal\n", LOG_TAG);
    return 0;
}

static int calc_page_on_create(void *page, lv_obj_t* root, void *data)
{
    (void)page; (void)data;
    syslog(LOG_WARN, "%s page main on_create\n", LOG_TAG);
    calc_page_create(root);
    return 0;
}

static int calc_page_on_destroy(void *page, lv_obj_t* root, void *data)
{
    (void)page; (void)root; (void)data;
    syslog(LOG_WARN, "%s page main on_destroy\n", LOG_TAG);
    return 0;
}

static char APP_ICON[]  = "/data/calc_logo_112.png";

#ifdef CALC_NOTIFY_ON_INSTALL
static char notification_title[] = "Calculator";
static char notification_src[]   = "Calculator";
static char notification_body[]  = "Installed. Find me in apps.";

static struct notification_msg_t done_notification = {
    .message_id      = UINT64_C(0xBE57BEEF),
    .title           = notification_title,
    .source          = notification_src,
    .body            = notification_body,
    .small_icon_path = APP_ICON,
    .large_icon_path = APP_ICON,
    .start_reminder  = 1u,
};
#endif

/* Only the callbacks that upstream validated on device are wired; the other
 * lifecycle slots stay NULL so the firmware keeps its default behaviour
 * (their return-value semantics are not known yet). */
static miwear_app_t g_calc_app = {
    .proto_app = 0,
    .field_4   = 0,
    .name      = APP_NAME,
    .icon      = APP_ICON,
    .app_id    = CALC_APP_ID,
    .flags     = CALC_APP_FLAGS,
    .field_14  = 0,
    .field_18  = 0,
    .app_get_name = calc_app_get_name,
    .on_uninstall = 0,
    .field_24  = 0,
    .field_28  = 0,
    .field_2C  = 0,
    .field_30  = 0,
    .field_34  = 0,
    .on_signal = 0,
    .field_3C  = 0,
};

static miwear_page_t g_calc_page = {
    .parent_descriptor = 0,
    .page_name         = PAGE_NAME,
    .page_id           = CALC_PAGE_ID,
    .app_id            = CALC_APP_ID,
    .flags             = 0,
    .scheduler_deadline = 0,
    .scheduler_priority = 0,
    .async_destroy_state = 0,
    .lifecycle_state   = 0,
    .layer             = 1,
    .page_kind         = 0,
    .activity_context  = 0,
    .root_object         = 0,
    .on_signal           = calc_page_on_signal,
    .runtime_default_56  = 0,
    .registry_prev       = 0,
    .registry_next       = 0,
    .runtime_parent      = 0,
    .on_create           = calc_page_on_create,
    .on_resume           = 0,
    .on_newdata          = 0,
    .on_start            = 0,
    .on_pause            = 0,
    .on_stop             = 0,
    .on_destroy          = calc_page_on_destroy,
    .on_back             = 0,
    .on_keyevent         = 0,
    .get_scroll_obj      = 0,
};

static void register_app(void)
{
    if (app_lookup(CALC_APP_ID) != 0) {
        syslog(LOG_WARN, "%s app 0x%x already registered, skip\n",
               LOG_TAG, CALC_APP_ID);
        return;
    }

    miwear_page_t *pages[] = { &g_calc_page };
    int res = g_packagemanager_api->install(&g_calc_app, pages, 1);
    syslog(LOG_WARN, "%s pm install(%s) rc=%d\n", LOG_TAG, g_calc_app.name, res);
    if (res != 0)
        return;

    g_registered = 1;

    int rc = app_launcher_add(CALC_APP_ID);
    syslog(LOG_WARN, "%s app_launcher_add rc=%d\n", LOG_TAG, rc);

#ifdef CALC_NOTIFY_ON_INSTALL
    lvx_notification_insert_message(&done_notification);
#endif
    syslog(LOG_WARN, "%s registered; remove by reboot, NOT rmmod\n", LOG_TAG);
}

static void timer_callback(lv_timer_t *timer)
{
    (void)timer;
    lv_timer_delete(post_timer_id);
    post_timer_id = 0;

    register_app();

    syslog(LOG_WARN, "%s timer fired\n", LOG_TAG);
}

__attribute__((constructor)) int module_initialize(void)
{
    syslog(LOG_WARN, "%s loaded\n", LOG_TAG);

    /* UI/package-manager calls must run in the LVGL thread, not the shell
     * thread that executes insmod: defer through a one-shot LVGL timer. */
    post_timer_id = lv_timer_create(timer_callback, 500, 0);
    syslog(LOG_WARN, "%s lv_timer_create -> %p\n", LOG_TAG, post_timer_id);

    return 0;
}

__attribute__((destructor, used)) static void module_uninitialize(void)
{
    if (g_registered || post_timer_id) {
        /* Cannot veto: the loader frees our memory right after this returns. */
        syslog(LOG_ERR, "%s rmmod while %s -> firmware still points into freed "
               "module memory; reboot now\n", LOG_TAG,
               g_registered ? "app registered" : "timer pending");
    } else {
        syslog(LOG_WARN, "%s unloaded (nothing registered)\n", LOG_TAG);
    }
}
