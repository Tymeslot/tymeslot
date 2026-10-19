defmodule TymeslotWeb.AccountLive.DeleteAccountModal do
  @moduledoc """
  Confirmation modal for deleting one's own account, on `CoreComponents.modal`.

  Says plainly what happens before anything is confirmed: with a grace period,
  the date of the deletion, that the account is frozen until then and that
  signing in restores it; without one, that everything goes immediately.
  Either way, upcoming bookings are deleted from Tymeslot, guests are not
  notified, and existing calendar events and video links stay as they are.

  A password account confirms with its current password, an account without
  one by typing its email address. The optional reason picker appears only
  when feedback collection is on (`feedback_options` not empty). Events
  (`request_account_deletion`, `close_delete_account_modal`) go to
  `TymeslotWeb.AccountLive`, which owns the open state.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :confirmation, :atom, required: true, values: [:password, :email]
  attr :grace_days, :integer, required: true
  attr :deletion_date, :string, required: true
  attr :feedback_options, :list, required: true, doc: "[{label, value}], empty when off"
  attr :errors, :map, required: true

  @spec delete_account_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def delete_account_modal(assigns) do
    ~H"""
    <.modal
      id="delete-account-modal"
      show={true}
      on_cancel={JS.push("close_delete_account_modal")}
      size={:medium}
    >
      <:header>
        <span class="text-token-xl font-black tracking-tight">
          {dgettext("account", "Delete your account")}
        </span>
      </:header>

      <.form
        for={%{}}
        as={:delete_account}
        id="delete-account-form"
        phx-submit="request_account_deletion"
        class="space-y-5"
      >
        <p :if={@grace_days == 0} class="text-tymeslot-700">
          {dgettext(
            "account",
            "Your account and everything in it will be deleted immediately. This cannot be undone."
          )}
        </p>
        <div :if={@grace_days > 0} class="space-y-3 text-tymeslot-700">
          <p>
            {dgettext("account", "Your account will be deleted on %{date}.", date: @deletion_date)}
          </p>
          <p>
            {dgettext(
              "account",
              "Until then it is frozen and your booking page is offline. Sign in before that date to restore it."
            )}
          </p>
        </div>

        <.info_box variant={:warning}>
          <p>
            {dgettext(
              "account",
              "Your upcoming bookings will be deleted from Tymeslot. Your guests will not be notified."
            )}
          </p>
          <p class="mt-2">
            {dgettext(
              "account",
              "Calendar events and video links that already exist stay as they are. If a meeting will not take place, contact your guests yourself."
            )}
          </p>
        </.info_box>

        <.info_box :if={@errors[:base]} variant={:error} class="mb-0 p-4!">
          {List.first(@errors[:base])}
        </.info_box>

        <.input
          :if={@confirmation == :password}
          type="password"
          id="delete-account-current-password"
          name="delete_account[current_password]"
          value=""
          label={dgettext("account", "Current Password")}
          errors={@errors[:current_password] || []}
          required
          icon="hero-lock-closed"
        />
        <.input
          :if={@confirmation == :email}
          type="email"
          id="delete-account-confirm-email"
          name="delete_account[confirm_email]"
          value=""
          label={dgettext("account", "Type your email address to confirm")}
          errors={@errors[:confirm_email] || []}
          required
          icon="hero-envelope"
        />

        <div :if={@feedback_options != []} class="space-y-4">
          <.input
            type="select"
            id="delete-account-reason"
            name="delete_account[reason]"
            value=""
            label={dgettext("account", "Why are you leaving? (optional)")}
            prompt={dgettext("account", "Choose a reason")}
            options={@feedback_options}
          />
          <.input
            type="textarea"
            id="delete-account-comment"
            name="delete_account[comment]"
            value=""
            rows={3}
            maxlength={500}
            label={dgettext("account", "Anything else you would like to tell us? (optional)")}
          />
        </div>
      </.form>

      <:footer>
        <div class="flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
          <.action_button
            variant={:secondary}
            phx-click="close_delete_account_modal"
            class="w-full sm:w-auto"
          >
            {dgettext("account", "Cancel")}
          </.action_button>
          <.action_button
            type="submit"
            form="delete-account-form"
            variant={:danger}
            class="w-full sm:w-auto"
            phx-disable-with={dgettext("account", "Deleting...")}
          >
            {confirm_label(@grace_days)}
          </.action_button>
        </div>
      </:footer>
    </.modal>
    """
  end

  defp confirm_label(0), do: dgettext("account", "Delete account now")
  defp confirm_label(_days), do: dgettext("account", "Schedule deletion")
end
