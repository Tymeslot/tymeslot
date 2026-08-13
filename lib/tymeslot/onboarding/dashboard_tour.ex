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
    * `:requires` — condition key the caller's context must satisfy for the step
      to appear, or `nil` for a step that is always shown

  Anchors that only render under some condition are what `:requires` is for.
  Resolving the list against a context up front drops such a step outright,
  rather than letting the client spotlight a missing element, time out, and
  skip it, which leaves the host watching the progress count jump a number.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @type placement :: :top | :bottom | :left | :right | :bottom_end | :center

  @type step :: %{
          id: atom(),
          anchor: String.t() | nil,
          placement: placement(),
          title: String.t(),
          body: String.t(),
          requires: atom() | nil
        }

  @typedoc """
  Which optional anchors the dashboard is rendering, keyed by condition.
  An absent key means the condition is unmet, so its step is dropped.
  """
  @type context :: %{optional(atom()) => boolean()}

  @doc """
  The steps to show on a dashboard described by `context`.

  Steps declaring a `:requires` key appear only when `context` marks that
  condition true; every other step is always present.
  """
  @spec steps(context()) :: [step()]
  def steps(context) do
    Enum.filter(catalog(), fn
      %{requires: nil} -> true
      %{requires: condition} -> Map.get(context, condition, false)
    end)
  end

  @spec catalog() :: [step()]
  defp catalog do
    [
      %{
        id: :welcome,
        anchor: nil,
        placement: :center,
        requires: nil,
        title: dgettext("onboarding", "Welcome to your Tymeslot dashboard"),
        body: dgettext("onboarding", "Take 30 seconds to learn where everything lives.")
      },
      %{
        id: :sidebar_nav,
        anchor: "sidebar-nav",
        placement: :right,
        requires: nil,
        title: dgettext("onboarding", "Everything lives here"),
        body:
          dgettext(
            "onboarding",
            "Your calendar is home. Meetings, availability, integrations, and your profile are all one click away."
          )
      },
      # `:bottom`, not `:top`: on the calendar this strip is pinned just under
      # the header, so there is no room for a tooltip above it. The checklist
      # hides itself once setup is complete or the host closes it, hence
      # `:requires`.
      %{
        id: :quick_actions,
        anchor: "quick-actions",
        placement: :bottom,
        requires: :checklist_visible?,
        title: dgettext("onboarding", "Your setup checklist"),
        body:
          dgettext(
            "onboarding",
            "Open it to connect a calendar, customise your booking page, and share your link. It disappears once every step is done."
          )
      },
      %{
        id: :user_menu,
        anchor: "user-menu",
        placement: :bottom_end,
        requires: nil,
        title: dgettext("onboarding", "Your account"),
        body: dgettext("onboarding", "Account settings and log out are here in the top-right.")
      },
      %{
        id: :done,
        anchor: nil,
        placement: :center,
        requires: nil,
        title: dgettext("onboarding", "You're set"),
        body: dgettext("onboarding", "Go create your first event type - and let people book you.")
      }
    ]
  end
end
