defmodule Tymeslot.Onboarding.DashboardTour do
  @moduledoc """
  Step catalog for the post-onboarding dashboard tour.

  Each step is a map of:

    * `:id` — unique atom identifying the step
    * `:anchor` — string matching a `data-tour="..."` attribute in the dashboard
      layout, or `nil` for a centred (non-spotlit) step
    * `:placement` — one of `:top`, `:bottom`, `:left`, `:right`, `:bottom_end`,
      `:center`
    * `:title` — gettext-translated headline string
    * `:body` — gettext-translated body string
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @type placement :: :top | :bottom | :left | :right | :bottom_end | :center

  @type step :: %{
          id: atom(),
          anchor: String.t() | nil,
          placement: placement(),
          title: String.t(),
          body: String.t()
        }

  @spec steps() :: [step()]
  def steps do
    [
      %{
        id: :welcome,
        anchor: nil,
        placement: :center,
        title: gettext("Welcome to your Tymeslot dashboard"),
        body: gettext("Take 30 seconds to learn where everything lives.")
      },
      %{
        id: :mode_tabs,
        anchor: "mode-tabs",
        placement: :bottom,
        title: gettext("Two modes"),
        body:
          gettext("Switch between Scheduling (your event types) and Calendar (your bookings).")
      },
      %{
        id: :sidebar_nav,
        anchor: "sidebar-nav",
        placement: :right,
        title: gettext("Settings live in the sidebar"),
        body: gettext("Profile, availability, integrations, and automation — all one click away.")
      },
      %{
        id: :quick_actions,
        anchor: "quick-actions",
        placement: :top,
        title: gettext("Common tasks"),
        body:
          gettext(
            "Quick links to set up your profile, availability, and meeting types. Start here."
          )
      },
      %{
        id: :user_menu,
        anchor: "user-menu",
        placement: :bottom_end,
        title: gettext("Your account"),
        body: gettext("Account settings and log out are here in the top-right.")
      },
      %{
        id: :done,
        anchor: nil,
        placement: :center,
        title: gettext("You're set"),
        body: gettext("Go create your first event type — and let people book you.")
      }
    ]
  end

  @spec count() :: non_neg_integer()
  def count, do: length(steps())
end
