/**
 * Dashboard Bundle
 *
 * Loaded on dashboard pages (/dashboard/*).
 * Includes dashboard-specific features with lazy-loaded hooks.
 */

import { initializeBundle } from "./bundle_utils"
import { lazyHook } from "../dynamic_hooks"
import { ServerUrlField } from "../hooks/server_url_field"

// Define dashboard-specific hooks (lazy-loaded to minimize initial bundle size,
// except where a hook is too small for a separate request to pay for itself)
const DashboardHooks = {
  // Registered eagerly: it is a few lines, and it has to be in place before
  // the first submit of an integration form rather than one request later.
  // `lazyHook` also shares one hook object across every element carrying the
  // hook, and the integration edit dialog renders two server URL fields.
  ServerUrlField,
  AutoUpload: lazyHook("AutoUpload", () => import("../hooks/auto_upload")),
  EmbedPreview: lazyHook("EmbedPreview", () => import("../hooks/embed_preview")),
  MeetingTypeSortable: lazyHook("MeetingTypeSortable", () => import("../hooks/meeting_type_sortable")),
  QuestionsSortable: lazyHook("QuestionsSortable", () => import("../hooks/questions_sortable")),
  CalendarDrag: lazyHook("CalendarDrag", () => import("../hooks/calendar_drag").then(m => m.CalendarDrag)),
  CalendarResize: lazyHook("CalendarResize", () => import("../hooks/calendar_drag").then(m => m.CalendarResize)),
  CalendarCreate: lazyHook("CalendarCreate", () => import("../hooks/calendar_drag").then(m => m.CalendarCreate)),
  CalendarMobile: lazyHook("CalendarMobile", () => import("../hooks/calendar_drag").then(m => m.CalendarMobile)),
  DesktopReminders: lazyHook("DesktopReminders", () => import("../hooks/desktop_reminders").then(m => m.DesktopReminders)),
  CustomColourPicker: lazyHook("CustomColourPicker", () => import("../hooks/custom_colour_picker").then(m => m.CustomColourPicker)),
  DashboardTour: lazyHook("DashboardTour", () => import("../hooks/dashboard_tour").then(m => m.DashboardTour)),
  AgendaCountdown: lazyHook("AgendaCountdown", () => import("../hooks/agenda_countdown").then(m => m.AgendaCountdown)),
};

// Initialize bundle with shared utility (handles retry logic, errors, telemetry)
initializeBundle("dashboard", DashboardHooks).catch(error => {
  console.error("Dashboard bundle initialization failed:", error);
});
