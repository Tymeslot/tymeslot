defmodule Tymeslot.Onboarding.DashboardTour do
  @moduledoc """
  Step catalog for the post-onboarding dashboard tour shown on first dashboard visit.

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
        title: dgettext("onboarding", "Welcome to your Tymeslot dashboard"),
        body: dgettext("onboarding", "Take 30 seconds to learn where everything lives.")
      },
      %{
        id: :sidebar_nav,
        anchor: "sidebar-nav",
        placement: :right,
        title: dgettext("onboarding", "Everything lives here"),
        body:
          dgettext(
            "onboarding",
            "Your calendar is home. Meetings, availability, integrations, and your profile are all one click away."
          )
      },
      %{
        id: :quick_actions,
        anchor: "quick-actions",
        placement: :top,
        title: dgettext("onboarding", "Common tasks"),
        body:
          dgettext(
            "onboarding",
            "Quick links to set up your profile, availability, and meeting types. Start here."
          )
      },
      %{
        id: :user_menu,
        anchor: "user-menu",
        placement: :bottom_end,
        title: dgettext("onboarding", "Your account"),
        body: dgettext("onboarding", "Account settings and log out are here in the top-right.")
      },
      %{
        id: :done,
        anchor: nil,
        placement: :center,
        title: dgettext("onboarding", "You're set"),
        body: dgettext("onboarding", "Go create your first event type - and let people book you.")
      }
    ]
  end

  @spec count() :: non_neg_integer()
  def count, do: length(steps())

  @spec step_at(non_neg_integer()) :: step() | nil
  def step_at(index), do: Enum.at(steps(), index)
end
