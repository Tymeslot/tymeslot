defmodule Tymeslot.Repo.Migrations.StripClickIdentifiersFromTrackingParams do
  @moduledoc """
  Removes ad click identifiers and Mailchimp subscriber ids from the
  `tracking_params` already stored on meetings and analytics events.

  Until this release, `Tymeslot.Analytics.UtmExtractor` kept per-click
  identifiers (`gclid`, `fbclid`, `msclkid`, ...) and Mailchimp's per-recipient
  `mc_eid`. The ad network or Mailchimp can resolve each one to a person, and on
  a meeting row it sat beside the invitee's name and email. New visits no longer
  store them; this strips them from the rows that already do.

  Where a row carried a click identifier, it gains `"ad_network"` naming the
  network instead, which is all the extractor records now. Campaign-level tags
  (`utm_*` columns, `ref`, `mc_cid`, `gclsrc`) are untouched.

  Rolling back is a no-op: the identifiers are gone, and restoring them would
  reintroduce the defect.
  """

  use Ecto.Migration

  # Mirrors the extractor's click-identifier map at the time of writing; a
  # migration must not read application code, which keeps changing after it.
  @networks [
    {"google", ~w(gclid gbraid wbraid dclid)},
    {"meta", ~w(fbclid)},
    {"microsoft", ~w(msclkid)},
    {"tiktok", ~w(ttclid)},
    {"x", ~w(twclid)},
    {"linkedin", ~w(li_fat_id)},
    {"yandex", ~w(yclid)},
    {"reddit", ~w(rdt_cid)},
    {"pinterest", ~w(epik)}
  ]

  # Personal identifiers dropped without recording a network: Instagram's
  # sharer id and Mailchimp's per-recipient id.
  @dropped_without_network ~w(igshid mc_eid)

  def up do
    for table <- ["meetings", "analytics_events"] do
      # A bounded one-shot scrub of a jsonb column; removing keys from a map
      # has no migration DSL form.
      # excellent_migrations:safety-assured-for-next-line raw_sql_executed
      execute(strip_sql(table))
    end
  end

  def down, do: :ok

  defp strip_sql(table) do
    removed = Enum.flat_map(@networks, fn {_network, keys} -> keys end) ++ @dropped_without_network

    """
    UPDATE #{table}
    SET tracking_params = (tracking_params - #{sql_array(removed)}) || #{network_case()}
    WHERE tracking_params ?| #{sql_array(removed)}
    """
  end

  defp network_case do
    branches =
      Enum.map_join(@networks, "\n", fn {network, keys} ->
        "WHEN tracking_params ?| #{sql_array(keys)} " <>
          "THEN jsonb_build_object('ad_network', '#{network}')"
      end)

    "CASE\n#{branches}\nELSE '{}'::jsonb\nEND"
  end

  defp sql_array(keys) do
    "ARRAY[" <> Enum.map_join(keys, ", ", &"'#{&1}'") <> "]::text[]"
  end
end
