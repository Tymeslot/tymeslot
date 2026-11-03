defmodule TymeslotWeb.OnboardingLiveStepTest do
  @moduledoc """
  The live step: the host's real page on the stage, and the keep actions,
  any one of which completes onboarding and stamps the first share, after
  which "Go to dashboard" only navigates. Opening the handoff link (the QR
  code) on another device counts as a keep too.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :onboarding

  import Mox
  import Tymeslot.AuthTestHelpers
  import TymeslotWeb.OnboardingTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Onboarding
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo
  alias Tymeslot.Utils.QrCode
  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.Live.Scheduling.PreviewMode

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    {:ok, view, _html, user} = setup_onboarding_with_calendar(setup_onboarding_session(tags.conn))
    navigate_to_ready_step(view)
    %{view: view, user: user}
  end

  defp completed_at(user), do: Repo.get!(UserSchema, user.id).onboarding_completed_at

  defp first_shared_at(user),
    do: Repo.get_by!(ProfileSchema, user_id: user.id).booking_link_first_shared_at

  defp profile(user), do: Repo.get_by!(ProfileSchema, user_id: user.id)

  describe "the stage" do
    test "shows the host's real page in preview mode", %{view: view, user: user} do
      [src] =
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.attribute("iframe#onboarding-stage-iframe", "src")

      # Relative, so the frame is same-origin (`frame-src 'self'`), and
      # marked as the stage's own frame.
      assert String.starts_with?(src, "/#{profile(user).username}?")
      assert src =~ "stage=1"
      assert src =~ "preview=true"
      assert src =~ "preview_token="
      # Only the QR link announces an opening; the stage's own page never.
      refute src =~ "handoff"

      assert has_element?(view, ~s(iframe#onboarding-stage-iframe[title="Your booking page"]))
    end

    test "a new username rebuilds the page the stage shows", %{view: view, user: user} do
      old = profile(user).username
      new = "renamed#{System.unique_integer([:positive])}"

      render_patch(view, "/onboarding/profile")
      fill_profile(view, "Test User", new)
      # link -> calendar -> meeting -> look -> live
      Enum.each(1..4, fn _step -> click_continue(view) end)

      [src] =
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.attribute("iframe#onboarding-stage-iframe", "src")

      assert String.starts_with?(src, "/#{new}?")
      refute src =~ "/#{old}?"
    end
  end

  describe "Go to dashboard" do
    test "Finish is locked until a keep action", %{view: view, user: user} do
      assert has_element?(
               view,
               ~s(#onboarding-finish[aria-disabled="true"][aria-describedby="onboarding-finish-helper"])
             )

      assert has_element?(view, "#onboarding-finish-helper", "Send or keep your link first")

      view |> element("#onboarding-finish") |> render_click()

      assert_push_event view, "share_link:focus", %{}
      assert has_element?(view, ".onboarding-step-title", "You're live")
      assert completed_at(user) == nil
    end

    test "after a keep it is the primary action and only navigates", %{view: view} do
      render_hook(view, "keep_link", %{"method" => "copy"})

      refute has_element?(view, "#onboarding-finish[aria-disabled]")
      assert has_element?(view, "#onboarding-finish.action-button--primary")

      view |> element("#onboarding-finish") |> render_click()
      assert_redirect(view, "/dashboard")
    end
  end

  describe "keep actions" do
    # `phone` is claimed by the handoff page alone ("the phone handoff" below).
    for method <- Onboarding.keep_methods() -- ["phone"] do
      test "#{method} completes onboarding and stamps the share", %{view: view, user: user} do
        :telemetry_test.attach_event_handlers(self(), [[:tymeslot, :onboarding, :link_kept]])

        render_hook(view, "keep_link", %{"method" => unquote(method)})

        assert %DateTime{} = completed_at(user)
        assert %DateTime{} = first_shared_at(user)
        refute has_element?(view, "#onboarding-finish[aria-disabled]")

        user_id = user.id

        assert_received {[:tymeslot, :onboarding, :link_kept], _ref, %{},
                         %{user_id: ^user_id, method: unquote(method)}}

        assert_push_event view, "ts:analytics", %{
          name: "booking_link_shared",
          props: %{channel: unquote(method)}
        }
      end
    end

    test "each button carries its own method", %{view: view, user: user} do
      view |> element("#onboarding-keep-copy") |> render_click()
      assert has_element?(view, "#onboarding-kept", "Copied")
      assert %DateTime{} = completed_at(user)

      view |> element("#onboarding-keep-signature") |> render_click()
      assert has_element?(view, "#onboarding-kept", "Signature copied")
      assert has_element?(view, "#onboarding-signature-help", "Gmail")

      view |> element("#onboarding-copy-message") |> render_click()
      assert has_element?(view, "#onboarding-kept", "Sent")
    end

    test "copy buttons copy the link and the signature line", %{view: view, user: user} do
      url = "/" <> profile(user).username

      copy = view |> element("#onboarding-keep-copy") |> render()
      assert copy =~ ~s(phx-hook="CopyOnClick")
      assert copy =~ ~r/data-copy-text="http[^"]*#{url}"/

      signature = view |> element("#onboarding-keep-signature") |> render()
      assert signature =~ ~r/data-copy-text="Book a time with me: http[^"]*#{url}"/
    end

    test "email me sends the email before counting", %{view: view, user: user} do
      view |> element("#onboarding-keep-email") |> render_click()

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_booking_link_email", "user_id" => user.id}
      )

      assert has_element?(view, "#onboarding-kept", "Emailed to you")
      assert has_element?(view, "#onboarding-email-sent", "Sent to #{user.email}")
      assert %DateTime{} = completed_at(user)
    end

    test "email me that cannot be sent completes nothing", %{view: view, user: user} do
      # Every job insert is refused at the database, as on an outage: the
      # constraint Oban's changeset names turns it into an error, not a
      # crash. The sandbox rolls the change back after the test, but until
      # then the DDL locks `oban_jobs` for every connection, which is why
      # this module must stay `async: false`.
      Repo.query!("ALTER TABLE oban_jobs DROP CONSTRAINT positive_max_attempts")

      Repo.query!(
        "ALTER TABLE oban_jobs ADD CONSTRAINT positive_max_attempts CHECK (false) NOT VALID"
      )

      html = view |> element("#onboarding-keep-email") |> render_click()

      assert html =~ "We couldn&#39;t send the email. Try another option."
      assert completed_at(user) == nil
      assert first_shared_at(user) == nil
      assert has_element?(view, ~s(#onboarding-finish[aria-disabled="true"]))
    end

    test "the client cannot claim the phone opening", %{view: view, user: user} do
      render_hook(view, "keep_link", %{"method" => "phone"})

      assert completed_at(user) == nil
      refute has_element?(view, "#onboarding-kept")
    end

    test "an unknown method is ignored", %{view: view, user: user} do
      render_hook(view, "keep_link", %{"method" => "fax"})

      assert completed_at(user) == nil
      assert first_shared_at(user) == nil
      refute has_element?(view, "#onboarding-kept")
      assert has_element?(view, ~s(#onboarding-finish[aria-disabled="true"]))
    end

    test "the first-person message includes the name", %{view: view, user: user} do
      view |> element("#onboarding-first-person-form") |> render_change(%{"name" => "Sam"})

      [text] =
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.attribute("#onboarding-send-link", "data-share-text")

      assert String.starts_with?(text, "Hi Sam, you can pick a time with me here: http")
      assert String.ends_with?(text, "/" <> profile(user).username)
      assert has_element?(view, ~s(#onboarding-send-link[phx-hook="ShareLink"]))
    end

    test "without a name the message is plain", %{view: view} do
      [text] =
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.attribute("#onboarding-send-link", "data-share-text")

      assert String.starts_with?(text, "You can pick a time with me here: http")
    end

    test "a reconnect after a keep comes back to the kept live step", %{view: view, user: user} do
      render_hook(view, "keep_link", %{"method" => "first_person"})

      conn =
        build_conn()
        |> setup_onboarding_session()
        |> log_in_user(Repo.get!(UserSchema, user.id))

      assert {:ok, again, _html} = live(conn, "/onboarding/ready")
      assert has_element?(again, ".onboarding-step-title", "You're live")
      assert has_element?(again, "#onboarding-kept", "Your link is saved")

      assert has_element?(
               again,
               "#onboarding-finish.action-button--primary[phx-click='next_step']"
             )

      refute has_element?(again, "#onboarding-finish[aria-disabled]")
    end

    test "an account completed over an hour ago is not sent back into setup", %{user: user} do
      user =
        user
        |> Changeset.change(
          onboarding_completed_at: DateTime.add(DateTime.utc_now(:second), -7200)
        )
        |> Repo.update!()

      conn = build_conn() |> setup_onboarding_session() |> log_in_user(user)

      assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, "/onboarding/ready")
    end

    test "closing the tab after a keep does not send the host back", %{view: view, user: user} do
      render_hook(view, "keep_link", %{"method" => "copy"})

      conn =
        build_conn()
        |> setup_onboarding_session()
        |> log_in_user(Repo.get!(UserSchema, user.id))

      assert {:ok, _dashboard, _html} = live(conn, "/dashboard")
    end
  end

  describe "the phone handoff" do
    test "the QR code carries the handoff link", %{view: view, user: user} do
      view |> element("#onboarding-keep-phone") |> render_click()

      doc = view |> render() |> Floki.parse_document!()
      [url] = Floki.attribute(doc, "#onboarding-handoff-qr", "data-handoff-url")

      [src] =
        Floki.attribute(
          doc,
          ~s(#onboarding-handoff-qr img[alt="QR code for your booking page"]),
          "src"
        )

      # Absolute, for a phone to open, and the one link that announces it.
      assert String.starts_with?(url, "http")
      assert url =~ "/#{profile(user).username}?"
      assert url =~ "handoff=1"
      assert src == QrCode.svg_data_uri(url)

      assert has_element?(view, "#onboarding-handoff-qr", "Scan with your phone camera.")
    end

    test "opening the handoff URL on another device completes onboarding", %{
      view: view,
      user: user
    } do
      username = profile(user).username
      path = PreviewMode.owner_path(username, user.id, handoff: true)
      assert path =~ "handoff=1"

      :telemetry_test.attach_event_handlers(self(), [[:tymeslot, :onboarding, :link_kept]])
      {:ok, _page, _html} = live(build_conn(), path)

      assert has_element?(view, "#onboarding-kept", "Opened on your phone")
      user_id = user.id

      assert_received {[:tymeslot, :onboarding, :link_kept], _ref, %{},
                       %{user_id: ^user_id, method: "phone"}}

      assert has_element?(view, ~s([data-role="stage-announcement"]), "Opened on your phone")
      assert %DateTime{} = completed_at(user)
      assert %DateTime{} = first_shared_at(user)
    end
  end
end
