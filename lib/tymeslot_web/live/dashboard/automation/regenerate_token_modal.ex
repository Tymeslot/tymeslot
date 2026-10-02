defmodule TymeslotWeb.Dashboard.Automation.RegenerateTokenModal do
  @moduledoc """
  Confirmation before a webhook security token is regenerated, which invalidates the current one.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :show, :boolean, default: false
  attr :on_cancel, :any, required: true
  attr :on_confirm, :any, required: true

  @spec regenerate_token_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def regenerate_token_modal(assigns) do
    ~H"""
    <.confirm_modal
      id="regenerate-token-modal"
      show={@show}
      size={:small}
      title={dgettext("dashboard_automation", "Regenerate Token?")}
      confirm_label={dgettext("dashboard_automation", "Regenerate")}
      on_cancel={@on_cancel}
      on_confirm={@on_confirm}
    >
      <p>
        {dgettext(
          "dashboard_automation",
          "Are you sure? The current security token will be immediately invalidated and any existing integrations using it will stop working."
        )}
      </p>
    </.confirm_modal>
    """
  end
end
