defmodule TymeslotWeb.AccountRestoreController do
  @moduledoc """
  The one page an account pending deletion can reach while signed in
  (`RequireAuthPlug` and `AuthLiveSessionHook` send it here from everywhere
  else). It shows when the account will be deleted and offers to restore it
  or to sign out, and nothing of the account's data.

  Once the scheduled date has passed (or the account is already gone) the
  page says the account can no longer be restored and offers only to sign
  out; a restore posted in that state shows the same page.

  Anyone not signed in goes to the login page; an account that is not
  pending goes to the dashboard.
  """

  use TymeslotWeb, :controller
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Auth
  alias Tymeslot.Infrastructure.Config
  alias TymeslotWeb.AccountRestoreHTML
  alias TymeslotWeb.Helpers.DeletionDate

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    case conn.assigns[:current_user] do
      nil ->
        redirect(conn, to: ~p"/auth/login")

      user ->
        if Auth.deletion_pending?(user), do: render_page(conn, user), else: to_dashboard(conn)
    end
  end

  @spec restore(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def restore(conn, _params) do
    case conn.assigns[:current_user] do
      nil -> redirect(conn, to: ~p"/auth/login")
      user -> restore_user(conn, user)
    end
  end

  defp restore_user(conn, user) do
    case Auth.restore_account(user) do
      {:ok, _restored} ->
        conn
        |> put_flash(
          :info,
          dgettext(
            "auth",
            "Welcome back. Your account has been restored and will not be deleted."
          )
        )
        |> to_dashboard()

      {:error, :not_pending} ->
        to_dashboard(conn)

      {:error, reason} when reason in [:deletion_in_progress, :not_found] ->
        render_expired(conn)

      {:error, _unexpected} ->
        render_page(
          conn,
          user,
          dgettext("auth", "Your account could not be restored. Please try again.")
        )
    end
  end

  defp render_page(conn, user, error \\ nil) do
    if Auth.account_restorable?(user, DateTime.utc_now()) do
      conn
      |> prepare()
      |> render(:show,
        deletion_date: DeletionDate.format(user.deletion_scheduled_at, user),
        error: error
      )
    else
      render_expired(conn)
    end
  end

  defp render_expired(conn) do
    conn |> prepare() |> render(:expired)
  end

  defp prepare(conn) do
    conn |> put_layout(html: false) |> put_view(html: AccountRestoreHTML)
  end

  defp to_dashboard(conn), do: redirect(conn, to: Config.success_redirect_path())
end
