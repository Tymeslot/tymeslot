defmodule TymeslotWeb.Dashboard.Automation.DeleteTelegramModal do
  @moduledoc """
  Confirmation before a Telegram integration and its delivery logs are deleted.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :show, :boolean, default: false
  attr :on_cancel, :any, required: true
  attr :on_confirm, :any, required: true

  @spec delete_telegram_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def delete_telegram_modal(assigns) do
    ~H"""
    <.confirm_modal
      id="delete-telegram-modal"
      show={@show}
      size={:small}
      title={dgettext("dashboard_automation", "Delete Telegram Integration?")}
      confirm_label={dgettext("dashboard_automation", "Delete Integration")}
      on_cancel={@on_cancel}
      on_confirm={@on_confirm}
    >
      <p>
        {dgettext(
          "dashboard_automation",
          "This action cannot be undone. All delivery logs for this integration will also be deleted."
        )}
      </p>
    </.confirm_modal>
    """
  end
end
