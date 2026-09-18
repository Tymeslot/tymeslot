defmodule Tymeslot.Repo.Migrations.NormaliseUrlKeyedVideoAccountIds do
  @moduledoc """
  Rewrites the account key of MiroTalk, Jitsi and custom video link
  integrations to the normalised form of their current address.

  These integrations are keyed (`provider_account_id`) on the address the
  organiser typed. Until this release the key was that address exactly as
  typed, and editing the address never moved the key, so a row could keep the
  key of a server it no longer points at, and the same server written with a
  trailing `/` or a capitalised host counted as a different one. New writes now
  key on the normalised address (`Tymeslot.Integrations.Video.AccountKey`);
  this brings existing rows in line.

  ## Which rows

  Every row of the three providers whose key differs from the normalised form
  of its address, soft-deleted and inactive rows included. A row without an
  address is left alone. `is_active` is nullable, and a NULL row is outside the
  partial index (`is_active = true`), so it counts as inactive.

  The partial unique index `unique_active_video_account_per_user` allows one
  active row per user, provider and key. An active row is therefore only
  rewritten when no other active row of the same user and provider holds, or
  is about to take, the new key. Two active rows for the same server are a
  real duplicate the owner has to resolve; they keep their current keys, and
  the duplicate check at creation compares normalised keys, so neither can be
  connected a third time. Each pass writes only keys no active row held when
  it started, so no statement can meet a key another statement has just
  freed, and passes repeat until a pass rewrites nothing.

  The normalising is a copy of `AccountKey.from_url/1` as of this release, so
  the migration keeps producing the same keys whatever that module becomes.

  Rolling back is a no-op: the addresses as typed are not kept anywhere, and a
  normalised key identifies the same server.
  """

  use Ecto.Migration

  # A one-shot data repair of rows earlier releases wrote; it changes no
  # column definition.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed

  @providers ["mirotalk", "jitsi", "custom"]
  @batch_size 500

  def up do
    execute(fn -> normalise_keys() end)
  end

  def down, do: :ok

  defp normalise_keys do
    rows = load_rows()
    changes = plan(rows)

    changes
    |> Enum.chunk_every(@batch_size)
    |> Enum.each(&write_keys/1)

    case changes do
      [] -> :ok
      _written -> normalise_keys()
    end
  end

  defp load_rows do
    %{rows: rows} =
      repo().query!(
        """
        SELECT id, user_id, provider, COALESCE(is_active, false), provider_account_id,
               CASE WHEN provider = 'custom' THEN custom_meeting_url ELSE base_url END
        FROM video_integrations
        WHERE provider = ANY($1)
        ORDER BY id
        """,
        [@providers]
      )

    Enum.map(rows, fn [id, user_id, provider, active?, key, url] ->
      %{id: id, user_id: user_id, provider: provider, active?: active?, key: key, url: url}
    end)
  end

  # The `{id, new_key}` pairs one pass writes.
  defp plan(rows) do
    rows
    |> Enum.group_by(&{&1.user_id, &1.provider})
    |> Enum.flat_map(fn {_owner, group} -> plan_group(group) end)
  end

  defp plan_group(group) do
    held = for %{active?: true, key: key} <- group, is_binary(key), into: MapSet.new(), do: key

    {changes, _taken} =
      Enum.reduce(group, {[], held}, fn row, {changes, taken} ->
        new_key = from_url(row.url)

        cond do
          is_nil(new_key) or new_key == row.key -> {changes, taken}
          not row.active? -> {[{row.id, new_key} | changes], taken}
          MapSet.member?(taken, new_key) -> {changes, taken}
          true -> {[{row.id, new_key} | changes], MapSet.put(taken, new_key)}
        end
      end)

    Enum.reverse(changes)
  end

  defp write_keys(changes) do
    {ids, keys} = Enum.unzip(changes)

    repo().query!(
      """
      UPDATE video_integrations AS v
      SET provider_account_id = d.key, updated_at = NOW()
      FROM unnest($1::bigint[], $2::text[]) AS d(id, key)
      WHERE v.id = d.id
      """,
      [ids, keys]
    )
  end

  # A copy of `Tymeslot.Integrations.Video.AccountKey.from_url/1`.
  defp from_url(url) when is_binary(url) do
    case String.trim(url) do
      "" -> nil
      trimmed -> trimmed |> URI.parse() |> normalise(trimmed)
    end
  end

  defp from_url(_url), do: nil

  defp normalise(%URI{scheme: scheme, host: host} = uri, _trimmed)
       when is_binary(scheme) and is_binary(host) and host != "" do
    URI.to_string(%URI{uri | host: String.downcase(host), path: trim_path(uri.path)})
  end

  defp normalise(_not_an_address, trimmed), do: String.trim_trailing(trimmed, "/")

  defp trim_path(nil), do: nil

  defp trim_path(path) do
    case String.trim_trailing(path, "/") do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
