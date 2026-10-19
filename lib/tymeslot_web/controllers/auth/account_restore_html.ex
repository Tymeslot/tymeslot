defmodule TymeslotWeb.AccountRestoreHTML do
  @moduledoc """
  The restore page for an account pending deletion. Deliberately bare: the
  date, a button to restore and a button to sign out, and no dashboard
  chrome, so nothing of the account's data is shown while it is frozen.
  Once the date has passed, `expired/1` says the account can no longer be
  restored and offers only the sign-out button.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Shared.Auth.LayoutComponents, only: [auth_card_layout: 1]

  attr :deletion_date, :string, required: true
  attr :error, :string, default: nil

  @spec show(map()) :: Phoenix.LiveView.Rendered.t()
  def show(assigns) do
    ~H"""
    <.auth_card_layout title={dgettext("auth", "Your account is being deleted")} video={false}>
      <:heading><.clock_badge /></:heading>
      <:form>
        <p class="text-center text-token-base text-tymeslot-600">
          {dgettext(
            "auth",
            "Your account is in the process of being deleted (scheduled for %{date}). If you want to keep it, restore it here.",
            date: @deletion_date
          )}
        </p>

        <.info_box :if={@error} variant={:error} class="mb-0 text-left">{@error}</.info_box>

        <form method="post" action={~p"/auth/restore"}>
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <.action_button type="submit" class="w-full">
            {dgettext("auth", "Restore my account")}
          </.action_button>
        </form>

        <.sign_out />
      </:form>
    </.auth_card_layout>
    """
  end

  @spec expired(map()) :: Phoenix.LiveView.Rendered.t()
  def expired(assigns) do
    ~H"""
    <.auth_card_layout title={dgettext("auth", "Your account is being deleted")} video={false}>
      <:heading><.clock_badge /></:heading>
      <:form>
        <p class="text-center text-token-base text-tymeslot-600">
          {dgettext("auth", "Your account is being deleted and can no longer be restored.")}
        </p>

        <.sign_out />
      </:form>
    </.auth_card_layout>
    """
  end

  defp clock_badge(assigns) do
    ~H"""
    <div class="mx-auto mb-6 flex h-16 w-16 items-center justify-center rounded-token-full bg-amber-100 text-amber-600">
      <.icon name="hero-clock" class="h-9 w-9" />
    </div>
    """
  end

  defp sign_out(assigns) do
    ~H"""
    <form method="post" action={~p"/auth/logout"}>
      <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
      <input type="hidden" name="_method" value="delete" />
      <.action_button type="submit" variant={:secondary} class="w-full">
        {dgettext("auth", "Sign out")}
      </.action_button>
    </form>
    """
  end
end
