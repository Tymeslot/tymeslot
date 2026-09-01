defmodule TymeslotWeb.AdminLive.Tabs do
  @moduledoc """
  The admin panel's tab structure: which settings sections each tab shows, and
  the order both are rendered in.

  One declaration drives three things that would otherwise drift apart: the tab
  bar in `Layout`, the sections `Settings` renders for the active tab, and the
  `live_action` values the router is allowed to hand this LiveView. Adding a
  settings section means adding it to exactly one list here, and a section
  missing from every tab is unreachable rather than silently rendered twice.

  `:users` is a tab but not a settings tab: it has its own component and no
  sections, so it lives in `all/0` and deliberately not in `@settings_tabs`.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  # Order matters twice over: tabs render left to right, and each tab's
  # sections render top to bottom.
  @settings_tabs [
    authentication: [:authentication, :recaptcha],
    email: [:admin_alerts, :email_branding],
    general: [:payments, :analytics]
  ]

  @settings_tab_names Keyword.keys(@settings_tabs)

  @type t :: :authentication | :email | :general | :users

  @doc "Every tab, in the order the tab bar renders them."
  @spec all() :: [t()]
  def all, do: @settings_tab_names ++ [:users]

  @doc "The tabs that render settings sections."
  @spec settings_tabs() :: [t()]
  def settings_tabs, do: @settings_tab_names

  @doc "Whether `tab` renders settings sections (as opposed to the users tab)."
  @spec settings_tab?(atom()) :: boolean()
  def settings_tab?(tab), do: tab in @settings_tab_names

  @doc """
  The settings sections `tab` renders, in order. A tab with no sections (the
  users tab) returns an empty list.
  """
  @spec sections(atom()) :: [atom()]
  def sections(tab), do: Keyword.get(@settings_tabs, tab, [])

  @doc "Human-readable label for a tab."
  @spec name(t()) :: String.t()
  def name(:authentication), do: dgettext("dashboard_admin", "Authentication")
  def name(:email), do: dgettext("dashboard_admin", "Email")
  def name(:general), do: dgettext("dashboard_admin", "General")
  def name(:users), do: dgettext("dashboard_admin", "Users")
end
