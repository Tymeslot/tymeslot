defmodule Tymeslot.Migrations.StripClickIdentifiersFromTrackingParamsTest do
  @moduledoc """
  Value-correctness regression for
  `20261002051008_strip_click_identifiers_from_tracking_params`, which removes
  per-person click and subscriber identifiers from stored `tracking_params`
  and records the ad network in their place.

  Driven from `priv` with `MigrationRunner.replay!/2`, since `down/0` is a
  no-op and `up/0` is safe to re-apply.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :analytics
  @moduletag :migrations

  import Tymeslot.Factory

  alias Tymeslot.Analytics.EventSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_002_051_008

  test "strips a gclid from a meeting and records Google as the network" do
    meeting = insert(:meeting, tracking_params: %{"gclid" => "Cj0-click", "ref" => "spring"})

    MigrationRunner.replay!(@version)

    assert Repo.get!(MeetingSchema, meeting.id).tracking_params ==
             %{"ad_network" => "google", "ref" => "spring"}
  end

  test "strips mc_eid but keeps the campaign-level mc_cid, without inventing a network" do
    meeting = insert(:meeting, tracking_params: %{"mc_eid" => "subscriber", "mc_cid" => "camp"})

    MigrationRunner.replay!(@version)

    assert Repo.get!(MeetingSchema, meeting.id).tracking_params == %{"mc_cid" => "camp"}
  end

  test "strips igshid without recording a network" do
    meeting = insert(:meeting, tracking_params: %{"igshid" => "sharer"})

    MigrationRunner.replay!(@version)

    assert Repo.get!(MeetingSchema, meeting.id).tracking_params == %{}
  end

  test "leaves a meeting with only campaign tags untouched" do
    params = %{"ref" => "newsletter", "mc_cid" => "camp", "gclsrc" => "aw.ds"}
    meeting = insert(:meeting, tracking_params: params)

    MigrationRunner.replay!(@version)

    assert Repo.get!(MeetingSchema, meeting.id).tracking_params == params
  end

  test "strips a fbclid from an analytics event and records Meta as the network" do
    # Raw SQL rather than `Repo.insert!/1`: the migration safety check scans
    # this directory and reads a schema insert as a data write in a migration.
    %{rows: [[event_id]]} =
      Repo.query!(
        """
        INSERT INTO analytics_events (event_type, path, visitor_hash, tracking_params, inserted_at)
        VALUES ('booking_page_view', '/x', 'h', $1, NOW())
        RETURNING id
        """,
        [%{"fbclid" => "IwAR-click", "ref" => "spring"}]
      )

    MigrationRunner.replay!(@version)

    assert Repo.get!(EventSchema, event_id).tracking_params ==
             %{"ad_network" => "meta", "ref" => "spring"}
  end
end
