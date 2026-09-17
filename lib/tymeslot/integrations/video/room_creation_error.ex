defmodule Tymeslot.Integrations.Video.RoomCreationError do
  @moduledoc """
  Why a video provider refuses to create rooms for an integration, and what the
  owner is told about it.

  A provider can accept an integration's credentials and still refuse every
  room, because of a setting on its own server: a Nextcloud that limits who may
  create conversations, or enforces a password on public ones. No retry fixes
  that, so the room job announces the booking without a link and gives up. The
  provider reports such a refusal as `{:configuration_error, code}` with one of
  `codes/0`, and `track/2` keeps it on the integration: its dashboard row
  explains it with `message/1`, and the owner is emailed about each code once.

  The error is recorded with the time it was first seen, and a later refusal
  with the same code keeps that time. It is cleared by the next room the
  integration creates, and by a change to its connection proven against the
  server (see `Tymeslot.Integrations.Video.VideoIntegrationQueries.update_credentials/2`).

  The credentials stay valid, so a refusal never flags the integration for
  reconnection: that flag makes every provider call refuse locally, which would
  also stop reschedules and deletions of rooms that already exist.

  Each code is emailed at most once per integration, ever. The claim is a
  single conditional update of the integration row, so two room jobs failing
  at once, or a job retried, cannot both claim it; the email job is queued in
  the same transaction, so a claim never stands without its email.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Repo

  require Logger

  @typedoc """
  A refusal the provider's answer tells apart:

    * `:conversation_creation_restricted`: the server lets only some groups create conversations
    * `:talk_not_allowed`: the server lets only some groups use Talk at all
    * `:password_required`: the server enforces a password on public conversations
    * `:talk_not_found`: nothing answers the conversation API at the server address
    * `:redirected`: the server redirects the conversation API elsewhere
    * `:conversation_refused`: any other refusal that repeats on every attempt
  """
  @type code ::
          :conversation_creation_restricted
          | :talk_not_allowed
          | :password_required
          | :talk_not_found
          | :redirected
          | :conversation_refused

  @doc "Every code a refusal can be recorded with."
  @spec codes() :: [code()]
  def codes, do: Ecto.Enum.values(VideoIntegrationSchema, :room_creation_error)

  @doc """
  Keeps an integration's recorded refusal in step with the outcome of a room
  creation for it.

  A created room clears a recorded refusal. A refusal with a known code is
  recorded, and emailed about when the owner has not been told of that code
  before. Any other outcome, a timeout or an outage, says nothing about the
  server's settings and leaves the record alone.
  """
  @spec track(VideoIntegrationSchema.t(), {:ok, term()} | {:error, term()}) :: :ok
  def track(%VideoIntegrationSchema{room_creation_error: nil}, {:ok, _room}), do: :ok

  def track(%VideoIntegrationSchema{} = integration, {:ok, _room}) do
    VideoIntegrationQueries.clear_room_creation_error(integration.id)

    Logger.info("Video provider created a room again, clearing the recorded refusal",
      integration_id: integration.id,
      code: integration.room_creation_error
    )

    :ok
  end

  def track(%VideoIntegrationSchema{} = integration, {:error, {:configuration_error, code}})
      when is_atom(code) do
    if code in codes(), do: record(integration, code), else: :ok
  end

  def track(_integration, _outcome), do: :ok

  @doc """
  What the refusal means and how to fix it, in plain words and the current
  locale. Shown on the integration's dashboard row and in the email about it.
  """
  @spec message(code()) :: String.t()
  def message(:conversation_creation_restricted),
    do:
      dgettext(
        "dashboard_integrations",
        "Nextcloud Talk does not allow this user to create conversations. In the Talk administration settings on Nextcloud, allow the user's group to create conversations, or connect a user who may."
      )

  def message(:talk_not_allowed),
    do:
      dgettext(
        "dashboard_integrations",
        "This Nextcloud user may not use Talk. In the Talk administration settings on Nextcloud, add the user to a group that may use Talk, or connect a user who may."
      )

  def message(:password_required),
    do:
      dgettext(
        "dashboard_integrations",
        "Nextcloud Talk requires a password on public conversations, so guests could not join from the booking's link. In the Talk administration settings on Nextcloud, turn off the password requirement for public conversations."
      )

  def message(:talk_not_found),
    do:
      dgettext(
        "dashboard_integrations",
        "Nextcloud did not find Talk at this address. Check that the Talk app is installed and enabled, and that the server address is the one you open Nextcloud at."
      )

  def message(:redirected),
    do:
      dgettext(
        "dashboard_integrations",
        "Nextcloud redirected the request to create a conversation. Edit the integration and enter the address your browser ends up on when you open Nextcloud."
      )

  def message(:conversation_refused),
    do:
      dgettext(
        "dashboard_integrations",
        "Nextcloud Talk refused to create a conversation. Check the Talk administration settings on Nextcloud; the next booking tries again."
      )

  defp record(integration, code) do
    Logger.warning("Video provider refuses to create rooms for this integration",
      integration_id: integration.id,
      provider: integration.provider,
      code: code
    )

    VideoIntegrationQueries.record_room_creation_error(integration.id, code)
    notify_once(integration, code)
  end

  # The claim and the email job commit together: a job that cannot be queued
  # rolls the claim back, so the next refusal claims it again.
  defp notify_once(integration, code) do
    result =
      Repo.transaction(fn ->
        with true <-
               VideoIntegrationQueries.claim_room_creation_error_notice(integration.id, code),
             {:error, reason} <-
               EmailScheduler.schedule_video_room_creation_error_notification(
                 integration.user_id,
                 integration.id,
                 code
               ) do
          Repo.rollback(reason)
        end
      end)

    log_notify_failure(result, integration, code)
  end

  defp log_notify_failure({:ok, _claimed}, _integration, _code), do: :ok

  defp log_notify_failure({:error, reason}, integration, code) do
    Logger.error("Failed to queue the email about a video room creation refusal",
      integration_id: integration.id,
      code: code,
      reason: inspect(reason)
    )

    :ok
  end
end
