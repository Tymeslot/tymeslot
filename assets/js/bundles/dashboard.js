/**
 * Dashboard Bundle
 *
 * Loaded on dashboard pages (/dashboard/*).
 * Includes dashboard-specific features with lazy-loaded hooks.
 */

import { initializeBundle } from "./bundle_utils"
import { lazyHook } from "../dynamic_hooks"
import { ServerUrlField } from "../hooks/server_url_field"
import { ReminderCustomRow } from "../hooks/reminder_custom_row"
import { installKeyboardClick } from "../keyboard_click"
import { ChartReadout } from "../hooks/chart_readout"
import { UnsavedChanges } from "../hooks/unsaved_changes"

// Define dashboard-specific hooks (lazy-loaded to minimize initial bundle size,
// except where a hook is too small for a separate request to pay for itself)
const DashboardHooks = {
  // Registered eagerly: it is a few lines, and it has to be in place before
  // the first submit of an integration form rather than one request later.
  ServerUrlField,
  // Eager for the same reason: a lazy load could miss the first focusout.
  ReminderCustomRow,
  // Eager because it is a few lines and only ever handles a chart keypress.
  ChartReadout,
  // Eager: a lazy load could miss the first keystroke it has to count.
  UnsavedChanges,
  AutoUpload: lazyHook("AutoUpload", () => import("../hooks/auto_upload")),
  EmbedPreview: lazyHook("EmbedPreview", () => import("../hooks/embed_preview")),
  MeetingTypeSortable: lazyHook("MeetingTypeSortable", () => import("../hooks/meeting_type_sortable")),
  QuestionsSortable: lazyHook("QuestionsSortable", () => import("../hooks/questions_sortable")),
  CalendarCanvas: lazyHook("CalendarCanvas", () => import("../hooks/calendar_canvas").then(m => m.CalendarCanvas)),
  DesktopReminders: lazyHook("DesktopReminders", () => import("../hooks/desktop_reminders").then(m => m.DesktopReminders)),
  DesktopReminderPermission: lazyHook("DesktopReminderPermission", () => import("../hooks/desktop_reminder_permission").then(m => m.DesktopReminderPermission)),
  CustomColourPicker: lazyHook("CustomColourPicker", () => import("../hooks/custom_colour_picker").then(m => m.CustomColourPicker)),
  DashboardTour: lazyHook("DashboardTour", () => import("../hooks/dashboard_tour").then(m => m.DashboardTour)),
  AgendaCountdown: lazyHook("AgendaCountdown", () => import("../hooks/agenda_countdown").then(m => m.AgendaCountdown)),
};

// Enter and Space on agenda rows and cards that act as buttons.
installKeyboardClick(document);

// Initialize bundle with shared utility (handles retry logic, errors, telemetry)
initializeBundle("dashboard", DashboardHooks).catch(error => {
  console.error("Dashboard bundle initialization failed:", error);
});
