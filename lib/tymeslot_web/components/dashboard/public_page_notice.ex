defmodule TymeslotWeb.Components.Dashboard.PublicPageNotice do
  @moduledoc """
  The dashboard-wide warning that the host's public booking page is turning
  every visitor away, because no calendar a booking can be written to is
  connected (`LinkAccessPolicy.check_public_readiness/2`).

  It cannot be dismissed: the page stays dead until a calendar is connected,
  and a host who finished onboarding without one may never open the
  integrations page on their own. It is a notice and never a gate, so a host
  whose calendar stopped working keeps the whole dashboard and is offered a
  repair instead of a first connection (`has_calendar_connection` in the
  integration status tells the two apart).

  A calendar whose credentials were refused is still connected and bookable,
  so the page is ready by this rule and the refused calendar's own notice in
  `DashboardLayout` is the one that speaks.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Scheduling.LinkAccessPolicy

  @doc "Whether the notice has something to say: the public page is not ready."
  @spec visible?(map() | nil, map() | nil) :: boolean()
  def visible?(profile, integration_status),
    do:
      match?(
        {:error, _reason},
        LinkAccessPolicy.check_public_readiness(profile, integration_status)
      )

  attr :profile, :any, required: true
  attr :integration_status, :map, required: true

  @spec notice(map()) :: Phoenix.LiveView.Rendered.t()
  def notice(assigns) do
    assigns =
      assign(assigns,
        visible: visible?(assigns.profile, assigns.integration_status),
        repair: Map.get(assigns.integration_status || %{}, :has_calendar_connection, false)
      )

    ~H"""
    <div
      :if={@visible}
      id="public-page-notice"
      class="max-w-7xl mx-auto px-4 lg:px-8 pt-4"
      role="alert"
      data-testid="public-page-notice"
      data-kind={if @repair, do: "repair", else: "connect"}
    >
      <.info_box variant={:warning}>
        <div class="flex flex-wrap items-center gap-4">
          <.icon name="hero-exclamation-triangle" class="w-6 h-6 shrink-0" />
          <div class="flex-1 min-w-[14rem]">
            <p class="font-bold">
              {if @repair,
                do: dgettext("dashboard_common", "Your booking page has stopped taking bookings"),
                else: dgettext("dashboard_common", "Your booking page isn't taking bookings yet")}
            </p>
            <p class="text-token-sm">
              {if @repair,
                do:
                  dgettext(
                    "dashboard_common",
                    "None of your calendars can take a booking right now, so anyone who opens your link is told the page isn't available. Check your calendar connection to fix it."
                  ),
                else:
                  dgettext(
                    "dashboard_common",
                    "Anyone who opens your link is told the page isn't available until you connect a calendar."
                  )}
            </p>
          </div>
          <.action_link
            navigate={~p"/dashboard/integrations?tab=calendars"}
            variant={:primary}
            size={:sm}
            icon={if @repair, do: "hero-wrench-screwdriver", else: "hero-plus"}
            class="shrink-0"
            data-testid="public-page-notice-action"
          >
            {if @repair,
              do: dgettext("dashboard_common", "Fix calendar connection"),
              else: dgettext("dashboard_common", "Connect a calendar")}
          </.action_link>
        </div>
      </.info_box>
    </div>
    """
  end
end
