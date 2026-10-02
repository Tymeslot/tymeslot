defmodule TymeslotWeb.Dashboard.Automation.DeleteWebhookModal do
  @moduledoc """
  Confirmation before a webhook and its delivery logs are deleted.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :show, :boolean, default: false
  attr :id, :string, default: "delete-webhook-modal"
  attr :on_cancel, :any, required: true
  attr :on_confirm, :any, required: true

  @spec delete_webhook_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def delete_webhook_modal(assigns) do
    ~H"""
    <.confirm_modal
      id={@id}
      show={@show}
      size={:small}
      title={dgettext("dashboard_automation", "Delete Webhook?")}
      confirm_label={dgettext("dashboard_automation", "Delete Webhook")}
      on_cancel={@on_cancel}
      on_confirm={@on_confirm}
    >
      <p>
        {dgettext(
          "dashboard_automation",
          "This action cannot be undone. All delivery logs for this webhook will also be deleted."
        )}
      </p>
    </.confirm_modal>
    """
  end
end
