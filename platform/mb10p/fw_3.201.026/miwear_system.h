#ifndef MB10P_MIWEAR_SYSTEM_FW_3_201_026_H
#define MB10P_MIWEAR_SYSTEM_FW_3_201_026_H

/* Xiaomi Smart Band 10 Pro Global, firmware 3.201.026
 * (CONBINE_LTALM080_T3.201.026_09041709), vela_ap.bin loaded at 0x2C0C0000.
 *
 * Every binding of fw_3.101.043 was re-located in this image by masked
 * function-signature match and by voting over the call sites of the same
 * callers; veneers were also checked against the body of their target.
 *
 * Checked on a device (adapted Calculator build, owner-reported): syslog,
 * lv_timer_create/delete, g_packagemanager_api->install, app_launcher_add,
 * app_lookup and the widget bindings used by ui/calc_page.c. The remaining
 * bindings are offline-derived only. Note that the stock mb10p_app.c also
 * calls g_watchface_config / watchface_manager_* and
 * lvx_notification_insert_message, which that build did not exercise.
 *
 * MB10P_UNRESOLVED(): bindings with no unique match in this image are left
 * unbound on purpose. Using one stops the build with an undeclared
 * identifier named after the symbol, instead of calling a null/wrong
 * address at run time (unlike the (0) stubs in fw_3.201.016).
 */
#define MB10P_UNRESOLVED(sym) (__mb10p_fw_3_201_026_unresolved_##sym)

/* Convention (same as the other fw_* headers):
 *   - Code addresses carry `| 1` (Thumb bit) so BLX switches state.
 *   - Typedefs live in the matching family header (nuttx/syslog.h,
 *     nuttx/reminder.h, lvgl/timer.h, lvgl/control.h, miwear/app.h,
 *     nuttx/screen.h, misc/print.h).
 *   - DO NOT put new prototypes here; put them in the family header.
 */

#include "common/nuttx/syslog.h"
#include "common/nuttx/reminder.h"
#include "common/nuttx/notification.h"
#include "common/nuttx/screen.h"
#include "common/lvgl/timer.h"
#include "common/lvgl/control.h"
#include "common/miwear/app.h"
#include "common/miwear/watchface.h" /* for watchface_manager_delete_watchface_t / watchface_manager_reset_watchface_t typedefs; watchface_config_t (v2) comes from platform/mb10p/watchface_layout.h via the family dispatcher */
#include "common/misc/print.h" /* for the snprintf prototype */

/* ============================================================================
 * Logger
 * ============================================================================ */
#define syslog                       ((syslog_t)(0x2C1BEAB8 | 1))

/* ============================================================================
 * LVGL reminder subsystem (struct reminder_t in nuttx/reminder.h)
 * ============================================================================ */
#define lvx_reminder_set_uid           ((lvx_reminder_set_uid_t)         (0x2C7DB0EC | 1))
#define lvx_reminder_set_level         ((lvx_reminder_set_level_t)       (0x2C7DB0CC | 1))
#define lvx_reminder_set_vibration     ((lvx_reminder_set_vibration_t)   (0x2C7DB0DC | 1))
#define lvx_reminder_ignore_quiet_mode ((lvx_reminder_ignore_quiet_mode_t)(0x2C7DA63C | 1))
#define lvx_reminder_ignore_sleep_mode ((lvx_reminder_ignore_sleep_mode_t)(0x2C7DA654 | 1))
#define lvx_reminder_ignore_mute_mode  ((lvx_reminder_ignore_mute_mode_t) (0x2C7DA66C | 1))
#define lvx_reminder_set_flag_bit7     ((lvx_reminder_set_flag_bit7_t)   (0x2C7DA684 | 1))
#define lvx_reminder_set_kind_byte     ((lvx_reminder_set_kind_byte_t)   (0x2C7DB0FC | 1))
#define lvx_reminder_set_life_times    ((lvx_reminder_set_life_times_t)  (0x2C7DA61C | 1))
#define lvx_reminder_set_on_create     ((lvx_reminder_set_on_create_t)   (0x2C7DA594 | 1))
#define lvx_reminder_set_on_destroy    ((lvx_reminder_set_on_destroy_t)  (0x2C7DA5A4 | 1))
#define lvx_reminder_disable_backspace ((lvx_reminder_disable_backspace_t)(0x2C7DA564 | 1))
#define lvx_reminder_set_bell          ((lvx_reminder_set_bell_t)        (0x2C7DB1E4 | 1))
#define lvx_reminder_start             ((lvx_reminder_start_t)           (0x2C7DA6CC | 1))
#define lvx_reminder_cancel            ((lvx_reminder_cancel_t)          (0x2C7DB0B0 | 1))

/* ============================================================================
 * Notifications
 * ============================================================================ */
#define lvx_notification_insert_message  ((notification_insert_t)(0x2C7DBDC8 | 1))

/* ============================================================================
 * Built-in OTA reminder
 * ============================================================================ */
#define reminder_page_ota_start   ((reminder_page_ota_start_t)(0x2C4AB320 | 1))

/* ============================================================================
 * LVGL timer (typedefs in lvgl/timer.h)
 * ============================================================================ */
#define lv_timer_create               ((lv_timer_create_t)(0x2C558208 | 1)) /* veneer */
#define lv_timer_delete               ((lv_timer_delete_t)(0x2C558330 | 1)) /* veneer */

/* ============================================================================
 * LVGL control widgets (typedefs in lvgl/control.h)
 *
 * All `_create` functions are Thumb and follow the same pattern:
 *     lv_<class>_create(parent)
 *     -> lv_obj_class_create_obj_veneer2(&lv_<class>, parent)
 *     -> lv_obj_class_init_obj_veneer(obj, 0)
 *     -> return obj
 *
 * Bindings below use the generic lv_class_create_t typedef since every
 * constructor has signature `lv_obj_t *(*)(lv_obj_t *parent)`.
 * ============================================================================ */
#define lv_obj_create                 ((lv_obj_create_t)  (0x2C558560 | 1)) /* veneer */
#define lv_image_create               ((lv_obj_create_t)  (0x2C5587A0 | 1)) /* veneer */
#define lv_label_create               ((lv_class_create_t)(0x2C559B28 | 1)) /* veneer */

#define lv_analog_time_create         MB10P_UNRESOLVED(lv_analog_time_create)   /* no unique match */
#define lv_btn_create                 ((lv_obj_create_t)  (0x2C559998 | 1)) /* veneer */
#define lvx_btn_create                ((lv_class_create_t)(0x2C78A114 | 1))
#define lv_canvas_create              MB10P_UNRESOLVED(lv_canvas_create)   /* no unique match */
#define lv_crossview_create           ((lv_class_create_t)(0x2C483B50 | 1))
#define lv_sleepchart_create          ((lv_class_create_t)(0x2C5A422C | 1))
#define lv_curvedlabel_create         ((lv_class_create_t)(0x2C790A50 | 1))
#define lv_frameanim_create           ((lv_class_create_t)(0x2C792174 | 1))
#define lv_imglabel_create            MB10P_UNRESOLVED(lv_imglabel_create)   /* no unique match */
#define lv_indicator_create           MB10P_UNRESOLVED(lv_indicator_create)   /* no unique match */
#define lv_optionlist_create          ((lv_class_create_t)(0x2C7A0A10 | 1))
#define lv_slider_create              ((lv_class_create_t)(0x2C7A171C | 1))
#define lv_xview_create               ((lv_class_create_t)(0x2C7A22DC | 1))
#define lv_timeview_create            ((lv_class_create_t)(0x2C7A71BC | 1))
#define lv_xwin_create                ((lv_class_create_t)(0x2C7A8E0C | 1))
#define lv_zoombtn_create             ((lv_class_create_t)(0x2C7A9BB0 | 1))
#define lv_eventdispatch_create       ((lv_class_create_t)(0x2C7B6964 | 1))
#define lv_renderdata_create          ((lv_class_create_t)(0x2C7C9A54 | 1))
#define lv_render_file_create         ((lv_class_create_t)(0x2C7C9F6C | 1))
#define lv_imgarc_create              ((lv_class_create_t)(0x2C7CB524 | 1))
#define lv_slot_create                ((lv_class_create_t)(0x2C7CD674 | 1))
#define lv_text_create                ((lv_class_create_t)(0x2C7CE5B8 | 1))
#define lv_wfwidget_create            ((lv_class_create_t)(0x2C7D0B04 | 1))
#define lv_widgetlayout_create        MB10P_UNRESOLVED(lv_widgetlayout_create)   /* no unique match */

/* ============================================================================
 * LVGL generic widget methods (typedefs in lvgl/control.h)
 * Both are Thumb thunks that JUMPOUT into the apps/graphics/lvgl library.
 * ============================================================================ */
#define lv_obj_set_size               ((lv_obj_set_size_t)  (0x2C558EE0 | 1)) /* veneer */
#define lv_image_set_src              ((lv_image_set_src_t) (0x2C557DD0 | 1)) /* veneer */
#define lv_obj_add_event_cb           ((lv_obj_add_event_cb_t)(0x2C557DF0 | 1)) /* veneer */
#define lv_label_set_text             ((lv_label_set_text_t)(0x2C558FC0 | 1)) /* veneer */
#define lvx_btn_set_text_fmt               ((lvx_btn_set_text_fmt_t)  (0x2C78A328 | 1))
#define lv_obj_add_flag               ((lv_obj_add_flag_t)  (0x2C557C98 | 1)) /* veneer */
#define lv_obj_clear_flag             ((lv_obj_clear_flag_t)(0x2C559B38 | 1)) /* veneer */
#define lv_obj_align                  ((lv_obj_align_t)     (0x2C5593B0 | 1)) /* veneer */
#define lv_obj_align_to               ((lv_obj_align_to_t)  (0x2C5587C0 | 1)) /* veneer */
#define lv_obj_set_width              ((lv_obj_set_width_t) (0x2C558718 | 1)) /* veneer */
#define lv_obj_set_style_text_align   ((lv_obj_set_style_text_align_t)(0x2C5599A0 | 1)) /* veneer */
#define lv_label_set_long_mode       ((lv_label_set_long_mode_t)(0x2C5591F8 | 1)) /* veneer */

/* ============================================================================
 * stdio (typedefs/prototypes in misc/print.h)
 * Thumb, direct implementation -- not a thunk.
 * ============================================================================ */
#define snprintf                    ((int (*)(char *, size_t, const char *, ...))(0x2C1B8E6C | 1))

/* ---- Style setters (firmware exposes _v variants; the public API strips the suffix) ---- */
#define lv_obj_set_style_bg_color     ((lv_obj_set_style_bg_color_t)(0x2C5594B8 | 1)) /* veneer */
#define lvx_btn_set_style_bg_color    ((lvx_btn_set_style_bg_color_t)(0x2C78A1B0 | 1))
#define lv_obj_set_style_bg_opa       ((lv_obj_set_style_bg_opa_t)  (0x2C5594A0 | 1)) /* veneer */
#define lv_obj_set_style_pad_left     ((lv_obj_set_style_pad_t)    (0x2C558750 | 1)) /* veneer */
#define lv_obj_set_style_pad_right    ((lv_obj_set_style_pad_t)    (0x2C5591C8 | 1)) /* veneer */
#define lv_obj_set_style_pad_top      ((lv_obj_set_style_pad_t)    (0x2C557C40 | 1)) /* veneer */
#define lv_obj_set_style_pad_bottom   ((lv_obj_set_style_pad_t)    (0x2C559470 | 1)) /* veneer */
#define lv_obj_set_style_pad_row      MB10P_UNRESOLVED(lv_obj_set_style_pad_row)   /* no unique match */
#define lv_obj_set_style_pad_column   ((lv_obj_set_style_pad_t)    (0x2C559938 | 1)) /* veneer */
#define lvx_obj_set_style_text        ((lvx_obj_set_style_text_t)  (0x2C44A66C | 1))

/* ============================================================================
 * Event dispatcher + animation veneer family (typedefs in lvgl/control.h)
 * Names below are stripped of the firmware's `_veneer` suffix at the C
 * boundary -- the underlying symbols keep it.
 * ============================================================================ */
#define lvx_label_set_time_text       ((lvx_label_set_time_text_t)(0x2C78A4BC | 1))
#define lv_anim_set                   MB10P_UNRESOLVED(lv_anim_set)   /* no match; the 3.101.043 entry points at lv_timer_create */
#define lv_anim_start                 MB10P_UNRESOLVED(lv_anim_start)   /* no match; the 3.101.043 entry points into the lv_timer_* cluster */
#define lv_anim_del                   MB10P_UNRESOLVED(lv_anim_del)   /* no match; the 3.101.043 entry points at lv_timer_delete */

/* ============================================================================
 * lv_event_get_* family (typedefs in lvgl/control.h) -- small field readers
 * in the lv_event_t struct, exposed without the firmware's _veneer suffix.
 * ============================================================================ */
#define lv_obj_event                  ((lv_obj_event_t)           (0x2C78A73C | 1))
#define lv_obj_get_event_code         ((lv_obj_get_event_code_t)  (0x2C5589E0 | 1)) /* veneer */
#define lv_obj_get_target             ((lv_obj_get_target_t)      (0x2C559970 | 1)) /* veneer */
#define lv_obj_get_parent             MB10P_UNRESOLVED(lv_obj_get_parent)   /* no unique match */
#define lv_event_get_user_data        ((lv_event_get_user_data_t) (0x2C558070 | 1)) /* veneer */
#define lv_event_get_param            MB10P_UNRESOLVED(lv_event_get_param)   /* no match; the 3.101.043 entry points at lv_timer_create */

/* Firmware data addresses for the label-style structs that
 * lvx_obj_set_style_text pulls from. Cast to (lv_style_t *) at call sites.
 * The addresses are in the firmware SRAM region (0x20000000+). */
#define LB_TEXT_STYLE_1              ((uintptr_t)0x200D68F0)
#define LB_TEXT_STYLE_2              ((uintptr_t)0x200D68FC)
#define LB_TEXT_STYLE_3              ((uintptr_t)0x200D6A1C)

/* ============================================================================
 * Screen power management (typedefs in nuttx/screen.h)
 * All Thumb; |1 forces BLX into Thumb state. Functions are direct ARM code
 * (not thunks), sizes range from 0x3c to 0x7c bytes.
 * ============================================================================ */
#define screen_turn_on                       ((int (*)(const char *, int))                 (0x2C7B4AAC | 1))
#define screen_turn_off                      ((const char *(*)(const char *))             (0x2C7B4B00 | 1))
#define screen_set_keepon                    ((const char *(*)(const char *, int))       (0x2C7B4A08 | 1))
#define screen_toggle_keepon_duration        ((int (*)(const char *, int))                 (0x2C7B497C | 1))

#define screen_session_start                 ((int (*)(screen_session_t *, int))          (0x2C7B43DC | 1))
#define screen_session_stop                  ((int (*)(screen_session_t *))               (0x2C7B446C | 1))
#define screen_session_restore_default       ((int (*)(screen_session_t *))               (0x2C7B4738 | 1))
#define screen_session_set_full_power        ((int (*)(screen_session_t *, int))          (0x2C7B46E4 | 1))
#define screen_session_set_brightness_value  ((int (*)(screen_session_t *, int))          (0x2C7B468C | 1))
#define screen_session_set_auto_brightness   ((int (*)(screen_session_t *, int))          (0x2C7B4628 | 1))
#define screen_session_set_keepon             ((int (*)(screen_session_t *, int))          (0x2C7B45D4 | 1))
#define screen_session_set_touch_palm         ((int (*)(screen_session_t *, int))          (0x2C7B4580 | 1))
#define screen_session_set_wrist_drop         ((int (*)(screen_session_t *, int))          (0x2C7B452C | 1))

/* ============================================================================
 * miwear launcher / packagemanager dispatch (typedefs in miwear/app.h)
 *
 * packagemanager_api->install(...) resolves to a Thumb call directly.
 * ============================================================================ */
#define g_packagemanager_api           ((struct packagemanager_api_s *)0x200B72E0)
#define app_launcher_add              ((app_launcher_add_t)(0x2C48C3E4 | 1))
#define app_lookup                    ((app_lookup_t)(0x2C7AB19C | 1))

/* ============================================================================
 * Watchface manager (typedefs in miwear/watchface.h)
 *
 * g_watchface_config is the data pointer (no Thumb bit); the other two are
 * code. Bind when building with -DMB10P_FW_VERSION=3201026.
 * ============================================================================ */
#define g_watchface_config                      (*(watchface_config_t **)0x20100224)
#define watchface_manager_delete_watchface      ((watchface_manager_delete_watchface_t)(0x2C7D7444 | 1))
#define watchface_manager_reset_watchface       ((watchface_manager_reset_watchface_t)(0x2C5571C8 | 1))

#endif /* MB10P_MIWEAR_SYSTEM_FW_3_201_026_H */
