defmodule TymeslotWeb.Dashboard.ProfileSettings.EmailSendingCompletionTest do
  @moduledoc """
  Exercises activation at the asynchronous test-completion boundary.

  A stored, tested identity represents a completed SMTP test. The real component
  callback and domain activation run against the database without sending mail.
  Scripted-relay coverage lives in EmailSendingComponentTest.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :emails
  @moduletag :security

  import Phoenix.Component, only: [assign: 2]
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.EmailSendingTestHelpers

  alias Ecto.Changeset
  alias Phoenix.LiveView.Socket
  alias Tymeslot.EmailSending
  alias Tymeslot.EmailSending.Settings
  alias TymeslotWeb.Dashboard.ProfileSettings.EmailSending.ErrorMessages
  alias TymeslotWeb.Dashboard.ProfileSettings.EmailSendingComponent

  @attrs %{
    "host" => "smtp.example.com",
    "username" => "completed-smtp-username",
    "password" => "completed-smtp-password",
    "from_address" => "bookings@example.com",
    "from_name" => "Appointments"
  }

  setup do
    with_config(:tymeslot, user_smtp_enabled: true)
    user = insert(:user, verified_at: DateTime.utc_now())
    saved_smtp_settings(user, @attrs)
    {:ok, settings} = EmailSending.get_settings(user)
    {:ok, socket} = EmailSendingComponent.mount(%Socket{assigns: %{__changed__: %{}}})

    {:ok, socket} =
      EmailSendingComponent.update(
        %{
          id: "smtp-completion",
          current_user: user,
          smtp_settings_loaded: true,
          smtp_settings: nil
        },
        socket
      )

    {:noreply, socket} = EmailSendingComponent.handle_event("toggle_custom_smtp", %{}, socket)
    key = {:smtp_test, make_ref()}
    socket = assign(socket, pending: %{key: key, owner_id: user.id})
    %{user: user, settings: settings, socket: socket, key: key}
  end

  test "a matching successful result activates the exact tested revision", context do
    {:noreply, socket} = complete(context)
    {:ok, current} = EmailSending.get_settings(context.user)
    assert current.enabled
    assert current.id == context.settings.id
    assert current.tested_revision == current.revision
    assert Settings.version(socket.assigns.settings) == Settings.version(current)
    assert socket.assigns.custom_smtp_open
    assert socket.assigns.pending == nil
    assert socket.assigns.notice =~ "now active"
    assert_receive {:flash, {:info, "SMTP connection healthy. Settings saved and active."}}
    refute_received {:flash, {:error, _message}}
    refute :erlang.term_to_binary(socket.assigns) =~ @attrs["username"]
    refute :erlang.term_to_binary(socket.assigns) =~ @attrs["password"]
  end

  test "a cancelled test cannot activate a saved identity", context do
    context = %{context | socket: assign(context.socket, pending: nil, custom_smtp_open: false)}
    {:noreply, socket} = complete(context)
    {:ok, current} = EmailSending.get_settings(context.user)
    refute current.enabled
    assert Settings.version(current) == Settings.version(context.settings)
    refute socket.assigns.custom_smtp_open
    refute_received {:flash, _result}
  end

  test "even a matching task result cannot activate while the toggle is off", context do
    context = %{context | socket: assign(context.socket, custom_smtp_open: false)}
    {:noreply, socket} = complete(context)
    {:ok, current} = EmailSending.get_settings(context.user)
    refute current.enabled
    assert Settings.version(current) == Settings.version(context.settings)
    assert socket.assigns.pending == nil
    assert socket.assigns.notice == nil
    refute_received {:flash, _result}
  end

  test "superseded test results cannot notify or replace the current pending test", context do
    old_key = {:smtp_test, make_ref()}

    {:noreply, socket} =
      EmailSendingComponent.handle_async(old_key, {:ok, {:ok, context.settings}}, context.socket)

    assert socket.assigns.pending == context.socket.assigns.pending
    assert socket.assigns.settings == context.socket.assigns.settings
    refute_received {:flash, _result}
  end

  test "switching off in another tab invalidates a completed test before activation", context do
    other_tab = assign(context.socket, pending: nil)

    {:noreply, closed} =
      EmailSendingComponent.handle_event("toggle_custom_smtp", %{}, other_tab)

    refute closed.assigns.custom_smtp_open
    disabled = closed.assigns.settings
    assert disabled.revision > context.settings.revision
    refute disabled.enabled

    {:noreply, socket} = complete(context)
    {:ok, current} = EmailSending.get_settings(context.user)
    refute current.enabled
    assert Settings.version(current) == Settings.version(disabled)
    assert Settings.version(socket.assigns.settings) == Settings.version(disabled)
    assert socket.assigns.error_message == ErrorMessages.message(:stale)
    assert_receive {:flash, {:error, message}}
    assert message == ErrorMessages.message(:stale)
    refute_received {:flash, {:info, _message}}
  end

  test "a deleted and recreated identity cannot inherit an old test result", context do
    :ok = EmailSending.delete_settings(context.user, Settings.version(context.settings))
    replacement = saved_smtp_settings(context.user, @attrs)
    {:noreply, socket} = complete(context)
    {:ok, current} = EmailSending.get_settings(context.user)
    refute current.enabled
    assert current.id == replacement.id
    assert socket.assigns.settings.id == replacement.id
    assert socket.assigns.error_message == ErrorMessages.message(:stale)
  end

  test "verification is checked again before activation", context do
    context.user |> Changeset.change(verified_at: nil) |> Repo.update!()
    {:noreply, socket} = complete(context)
    {:ok, current} = EmailSending.get_settings(context.user)
    refute current.enabled
    assert Settings.version(current) == Settings.version(context.settings)
    assert Settings.version(socket.assigns.settings) == Settings.version(context.settings)
    assert socket.assigns.error_message == ErrorMessages.message(:unverified_user)
    assert_receive {:flash, {:error, message}}
    assert message == ErrorMessages.message(:unverified_user)
    refute_received {:flash, {:info, _message}}
  end

  test "deployment disablement prevents activation after a completed test", context do
    with_config(:tymeslot, user_smtp_enabled: false)
    {:noreply, socket} = complete(context)
    {:ok, current} = EmailSending.get_settings(context.user)
    refute current.enabled
    assert socket.assigns.pending == nil
    assert socket.assigns.error_message == ErrorMessages.message(:feature_disabled)
    assert_receive {:flash, {:error, message}}
    assert message == ErrorMessages.message(:feature_disabled)
    refute_received {:flash, {:info, _message}}
  end

  test "failed and crashed tests emit only sanitized errors", context do
    for {result, reason} <- [
          {{:ok, {:error, :authentication_failed}}, :authentication_failed},
          {{:ok, {:error, {:provider, @attrs["password"]}}}, :unexpected_failure},
          {{:exit, {:unexpected, @attrs["password"]}}, :unexpected_failure}
        ] do
      {:noreply, socket} =
        EmailSendingComponent.handle_async(context.key, result, context.socket)

      assert socket.assigns.pending == nil
      assert_receive {:flash, {:error, message}}
      assert message == ErrorMessages.message(reason)
      refute message =~ @attrs["password"]
      refute_received {:flash, {:info, _message}}
    end

    {:ok, current} = EmailSending.get_settings(context.user)
    refute current.enabled
    assert Settings.version(current) == Settings.version(context.settings)
  end

  # The task's public result is the only completion input; it carries neither
  # submitted credentials nor a client-controlled activation/version flag.
  defp complete(context) do
    EmailSendingComponent.handle_async(
      context.key,
      {:ok, {:ok, context.settings}},
      context.socket
    )
  end
end
