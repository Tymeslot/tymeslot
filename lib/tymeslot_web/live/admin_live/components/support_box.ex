defmodule TymeslotWeb.AdminLive.Components.SupportBox do
  @moduledoc """
  The "Support Tymeslot" card at the foot of every admin tab, asking the admin
  of a self-hosted install for three things: a GitHub star, a sponsorship, and
  bug reports.

  The report ask depends on admin alerts. An install with alerts off never
  hears about its own failures, so until they are set up the card asks for
  that first and links to the email tab; once they are, it asks for the
  alerts to be shared as GitHub issues.

  Every link is a plain outbound link with nothing recorded about the click:
  a self-hosted install sends nothing home.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  @repo_url "https://github.com/Tymeslot/tymeslot"
  @sponsor_url "https://github.com/sponsors/Tymeslot"
  @new_issue_url "https://github.com/Tymeslot/tymeslot/issues/new"

  attr :alerts_ready, :boolean,
    required: true,
    doc: "Admin alerts are enabled and have a recipient"

  @spec support_box(map()) :: Phoenix.LiveView.Rendered.t()
  def support_box(assigns) do
    assigns =
      assign(assigns,
        repo_url: @repo_url,
        sponsor_url: @sponsor_url,
        new_issue_url: @new_issue_url
      )

    ~H"""
    <.card
      id="admin-support-box"
      tag="aside"
      class="mt-12"
      icon="hero-heart"
      title={dgettext("dashboard_admin", "Support Tymeslot")}
      description={
        dgettext(
          "dashboard_admin",
          "Tymeslot is free to self-host. If it is useful to you, here are three ways to help it grow."
        )
      }
    >
      <ul class="grid gap-6 sm:grid-cols-3">
        <.ask
          id="support-star"
          icon="hero-star"
          title={dgettext("dashboard_admin", "Star us on GitHub")}
          body={dgettext("dashboard_admin", "Stars help other self-hosters find the project.")}
        >
          <.action_link
            href={@repo_url}
            target="_blank"
            rel="noopener noreferrer"
            variant={:secondary}
            size={:sm}
          >
            {dgettext("dashboard_admin", "Star on GitHub")}
          </.action_link>
        </.ask>

        <.ask
          id="support-sponsor"
          icon="hero-gift"
          title={dgettext("dashboard_admin", "Sponsor development")}
          body={
            dgettext(
              "dashboard_admin",
              "Sponsorship pays for the time that goes into new features and fixes."
            )
          }
        >
          <.action_link
            href={@sponsor_url}
            target="_blank"
            rel="noopener noreferrer"
            variant={:secondary}
            size={:sm}
          >
            {dgettext("dashboard_admin", "Become a sponsor")}
          </.action_link>
        </.ask>

        <.ask
          :if={!@alerts_ready}
          id="support-report"
          icon="hero-bell-alert"
          title={dgettext("dashboard_admin", "Turn on admin alerts")}
          body={
            dgettext(
              "dashboard_admin",
              "Alerts email you when something breaks on this install. Share what they catch on GitHub, so it gets fixed for everyone."
            )
          }
        >
          <.action_link navigate={~p"/admin/email"} variant={:secondary} size={:sm}>
            {dgettext("dashboard_admin", "Set up alerts")}
          </.action_link>
        </.ask>

        <.ask
          :if={@alerts_ready}
          id="support-report"
          icon="hero-bug-ant"
          title={dgettext("dashboard_admin", "Report what you find")}
          body={
            dgettext(
              "dashboard_admin",
              "When an admin alert arrives, share it as a GitHub issue (redacting anything sensitive), so it gets fixed for everyone."
            )
          }
        >
          <.action_link
            href={@new_issue_url}
            target="_blank"
            rel="noopener noreferrer"
            variant={:secondary}
            size={:sm}
          >
            {dgettext("dashboard_admin", "Open an issue")}
          </.action_link>
        </.ask>
      </ul>
    </.card>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, required: true
  slot :inner_block, required: true

  defp ask(assigns) do
    ~H"""
    <li id={@id} class="flex flex-col items-start gap-3">
      <.icon name={@icon} class="w-6 h-6 text-turquoise-600" />
      <div class="flex-1">
        <h3 class="text-token-base font-black text-tymeslot-900 tracking-tight">{@title}</h3>
        <p class="mt-1 text-token-sm text-tymeslot-600 font-medium leading-relaxed">{@body}</p>
      </div>
      {render_slot(@inner_block)}
    </li>
    """
  end
end
