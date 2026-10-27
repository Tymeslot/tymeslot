defmodule TymeslotWeb.AccountLive.DangerZone do
  @moduledoc """
  The last card on the account page: deleting the account. Opens
  `TymeslotWeb.AccountLive.DeleteAccountModal` through the
  `open_delete_account_modal` event, handled by `TymeslotWeb.AccountLive`.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :grace_days, :integer, required: true

  @spec danger_zone_card(map()) :: Phoenix.LiveView.Rendered.t()
  def danger_zone_card(assigns) do
    ~H"""
    <div id="danger-zone" class="card-glass">
      <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div class="min-w-0">
          <h3 class="text-lg font-medium text-red-700">{dgettext("account", "Delete account")}</h3>
          <p class="text-sm text-tymeslot-600 mt-1">{description(@grace_days)}</p>
          <p class="text-sm text-tymeslot-600 mt-1">
            {dgettext(
              "account",
              "Upcoming bookings are deleted from Tymeslot and your guests are not notified."
            )}
          </p>
        </div>
        <.action_button variant={:danger} phx-click="open_delete_account_modal" class="shrink-0">
          {dgettext("account", "Delete account")}
        </.action_button>
      </div>
    </div>
    """
  end

  defp description(0) do
    dgettext(
      "account",
      "Delete your account and everything in it immediately. This cannot be undone."
    )
  end

  defp description(days) do
    dngettext(
      "account",
      "If you delete your account, it is frozen for %{count} day, then deleted. Sign in during that time to restore it.",
      "If you delete your account, it is frozen for %{count} days, then deleted. Sign in during that time to restore it.",
      days
    )
  end
end
