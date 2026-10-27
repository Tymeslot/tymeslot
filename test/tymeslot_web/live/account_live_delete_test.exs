defmodule TymeslotWeb.AccountLiveDeleteTest do
  use TymeslotWeb.ConnCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Auth.AccountDeletion.Policy
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.AccountDeletionWorker
  alias TymeslotWeb.Helpers.LocaleFormat

  defmodule ForwardingHook do
    @moduledoc false
    @behaviour Tymeslot.Auth.Behaviours.AccountDeletionHook

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_deletion_requested(user_id, feedback) do
      send(
        Application.fetch_env!(:tymeslot, :deletion_hook_test_pid),
        {:requested, user_id, feedback}
      )

      :ok
    end

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_deletion_restored(_user_id), do: :ok

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_account_deletion(_user_id), do: :ok
  end

  setup %{conn: conn} do
    RateLimiter.clear_all()
    with_config(:tymeslot, account_deletion_grace_days: 14, collect_deletion_feedback: false)
    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    insert(:profile, user: user)
    %{conn: log_in_user(conn, user), user: user}
  end

  defp open_modal(conn) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/account")
    view |> element("#danger-zone button", "Delete account") |> render_click()
    view
  end

  defp submit(view, params) do
    view |> form("#delete-account-form", delete_account: params) |> render_submit()
  end

  # The redirect carries its flash as a signed token; the login page it lands
  # on is where the user reads it.
  defp login_page_html(result, conn) do
    {:ok, conn} = follow_redirect(result, conn)
    html_response(conn, 200)
  end

  test "the modal asks for the password and says what happens to bookings", %{conn: conn} do
    view = open_modal(conn)
    html = render(view)

    assert has_element?(view, "#delete-account-modal input[type=password]")
    assert html =~ "Your guests will not be notified"
    assert html =~ "Calendar events and video links that already exist stay as they are"
    assert html =~ "your booking page is offline"
    assert html =~ "Your account will be deleted on"
    refute has_element?(view, "#delete-account-reason")
  end

  test "a wrong password is reported in the modal and schedules nothing",
       %{conn: conn, user: user} do
    view = open_modal(conn)

    html = submit(view, %{current_password: "nope"})

    assert html =~ "Current password is incorrect"
    assert Repo.get(UserSchema, user.id).deletion_scheduled_at == nil
  end

  test "the right password schedules the deletion and signs the user out",
       %{conn: conn, user: user} do
    view = open_modal(conn)

    result = submit(view, %{current_password: "Password123!"})

    assert {:error, {:redirect, %{to: "/auth/login"}}} = result
    assert login_page_html(result, conn) =~ "will be deleted on"
    assert Repo.get(UserSchema, user.id).deletion_scheduled_at
    assert_enqueued(worker: AccountDeletionWorker, args: %{"user_id" => user.id})
  end

  test "with no grace period the copy and the outcome say deleted now", %{conn: conn} do
    with_config(:tymeslot, :account_deletion_grace_days, 0)
    view = open_modal(conn)
    html = render(view)
    assert html =~ "deleted immediately"
    refute html =~ "your booking page is offline"

    result = submit(view, %{current_password: "Password123!"})

    assert {:error, {:redirect, %{to: "/auth/login"}}} = result
    assert login_page_html(result, conn) =~ "Your account has been deleted."
  end

  test "an account without a password confirms with its address" do
    user =
      insert(:user,
        provider: "google",
        password_hash: nil,
        onboarding_completed_at: DateTime.utc_now(:second)
      )

    insert(:profile, user: user)
    view = build_conn() |> init_test_session(%{}) |> log_in_user(user) |> open_modal()

    assert has_element?(view, "#delete-account-modal input[type=email]")
    assert submit(view, %{confirm_email: "someone@else.test"}) =~ "That is not the email address"
  end

  defp email_user do
    user =
      insert(:user,
        provider: "google",
        password_hash: nil,
        onboarding_completed_at: DateTime.utc_now(:second)
      )

    insert(:profile, user: user)
    user
  end

  defp email_view(user),
    do: build_conn() |> init_test_session(%{}) |> log_in_user(user) |> open_modal()

  test "an account without a password schedules the deletion once its address is typed" do
    user = email_user()
    view = email_view(user)

    result = submit(view, %{confirm_email: user.email})

    assert {:error, {:redirect, %{to: "/auth/login"}}} = result
    assert Repo.get(UserSchema, user.id).deletion_scheduled_at
    assert_enqueued(worker: AccountDeletionWorker, args: %{"user_id" => user.id})
  end

  test "an unexpected failure is shown in the modal to an account that confirms by address" do
    user = email_user()
    view = email_view(user)
    Repo.delete!(user)

    html = submit(view, %{confirm_email: user.email})

    assert html =~ "Your account could not be scheduled for deletion"

    assert has_element?(view, "#delete-account-modal .bg-red-50")
  end

  test "the chosen reason and comment reach the deletion hook" do
    with_config(:tymeslot,
      collect_deletion_feedback: true,
      account_deletion_hook: ForwardingHook,
      deletion_hook_test_pid: self()
    )

    user = email_user()
    view = email_view(user)

    submit(view, %{confirm_email: user.email, reason: "too_expensive", comment: "Too dear"})

    user_id = user.id
    assert_receive {:requested, ^user_id, %{reason: "too_expensive", comment: "Too dear"}}
  end

  test "the deletion date is the user's own calendar day", %{conn: conn, user: user} do
    now = DateTime.utc_now()
    due = Policy.scheduled_at(now)
    utc_date = DateTime.to_date(due)

    timezone =
      Enum.find(["Pacific/Kiritimati", "Pacific/Pago_Pago"], fn zone ->
        Policy.local_date(due, zone) != utc_date
      end)

    profile = Repo.get_by!(ProfileSchema, user_id: user.id)
    profile |> Changeset.change(timezone: timezone) |> Repo.update!()

    html = conn |> open_modal() |> render()

    assert html =~ LocaleFormat.format_date(Policy.local_date(due, timezone), "en")
    refute html =~ LocaleFormat.format_date(utc_date, "en")
  end

  test "the reason picker is offered when feedback is collected", %{conn: conn} do
    with_config(:tymeslot, :collect_deletion_feedback, true)
    view = open_modal(conn)

    assert has_element?(view, "#delete-account-reason option[value=too_expensive]")
    assert has_element?(view, "#delete-account-comment")
  end

  test "cancel closes the modal", %{conn: conn} do
    view = open_modal(conn)
    view |> element("#delete-account-modal button", "Cancel") |> render_click()

    refute has_element?(view, "#delete-account-modal")
  end

  test "repeated wrong passwords end in a rate-limit message", %{conn: conn} do
    view = open_modal(conn)

    limited? =
      Enum.any?(1..30, fn _attempt ->
        submit(view, %{current_password: "nope"})
        view |> element("#app-flash-group") |> render() =~ "reached the limit"
      end)

    assert limited? == true
    refute render(view) =~ "Current password is incorrect"
  end
end
