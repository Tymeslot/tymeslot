defmodule Tymeslot.Notifications.IntegrationQueries do
  @moduledoc """
  Shared data-access boundary for notification provider integrations
  (Slack, Telegram, future providers).

  Outbound user notifications across multiple providers share common business
  concepts: a per-user collection of integrations, subscriptions to event
  types, active/paused state, a failure counter that gates auto-disabling,
  and per-delivery success/failure tracking. Their database rows therefore
  share the same CRUD shape — only the schema module and a handful of
  provider-specific quirks differ.

  This module exposes those shared CRUD and aggregate shapes parameterised
  by the schema module, so each provider's queries module can delegate the
  genuinely identical parts here and keep its own quirks local. It is **not**
  a generic technical layer: it is the data-access boundary for the
  Notifications domain, which Slack and Telegram both implement.

  Provider-specific quirks (e.g. `SlackQueries.delete_pending_stubs/1`'s
  OAuth-pending-stub cleanup, `TelegramQueries.find_by_link_token/1`'s
  link-token + chat-id lookup, Telegram's `derive_status/1` post-processing)
  stay in the per-provider query module.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Repo

  @doc """
  Returns all integration rows owned by `user_id`, newest first.
  """
  @spec list_for_user(module(), integer()) :: [Ecto.Schema.t()]
  def list_for_user(schema, user_id) do
    schema
    |> where([i], i.user_id == ^user_id)
    |> order_by([i], desc: i.inserted_at)
    |> Repo.all()
  end

  @doc """
  Looks up an integration by primary key.
  """
  @spec get(module(), integer()) :: {:ok, Ecto.Schema.t()} | {:error, :not_found}
  def get(schema, id) do
    case Repo.get(schema, id) do
      nil -> {:error, :not_found}
      integration -> {:ok, integration}
    end
  end

  @doc """
  Looks up an integration by primary key, scoped to `user_id`.
  """
  @spec get_for_user(module(), integer(), integer()) ::
          {:ok, Ecto.Schema.t()} | {:error, :not_found}
  def get_for_user(schema, id, user_id) do
    case Repo.get_by(schema, id: id, user_id: user_id) do
      nil -> {:error, :not_found}
      integration -> {:ok, integration}
    end
  end

  @doc """
  Inserts the given changeset.
  """
  @spec insert(Ecto.Changeset.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def insert(changeset), do: Repo.insert(changeset)

  @doc """
  Updates the given changeset.
  """
  @spec update(Ecto.Changeset.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def update(changeset), do: Repo.update(changeset)

  @doc """
  Deletes the given integration row.
  """
  @spec delete(Ecto.Schema.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def delete(integration), do: Repo.delete(integration)

  @doc """
  Atomically increments the `failure_count` column for the integration with
  the given primary key and returns the updated row.
  """
  @spec increment_failure(module(), integer()) ::
          {:ok, Ecto.Schema.t()} | {:error, :not_found}
  def increment_failure(schema, id) do
    case schema
         |> where([i], i.id == ^id)
         |> select([i], i)
         |> Repo.update_all(inc: [failure_count: 1]) do
      {0, _rows} ->
        {:error, :not_found}

      {_count, [updated]} ->
        {:ok, updated}
    end
  end

  @doc """
  Toggles the integration's `is_active` flag via `schema.changeset/2`.
  """
  @spec toggle_active(module(), Ecto.Schema.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def toggle_active(schema, integration) do
    integration
    |> schema.changeset(%{is_active: !integration.is_active})
    |> Repo.update()
  end

  @doc """
  Stamps the integration as successfully fired right now and resets the
  failure counter. Applied via `schema.changeset/2`.
  """
  @spec record_success(module(), Ecto.Schema.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def record_success(schema, integration) do
    integration
    |> schema.changeset(%{last_triggered_at: DateTime.utc_now(), failure_count: 0})
    |> Repo.update()
  end

  @doc """
  Re-enables an auto-disabled integration: clears `disabled_at` /
  `disabled_reason`, resets `failure_count`, and sets `is_active` to true.
  Applied via `schema.changeset/2`.
  """
  @spec enable(module(), Ecto.Schema.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def enable(schema, integration) do
    integration
    |> schema.changeset(%{
      is_active: true,
      disabled_at: nil,
      disabled_reason: nil,
      failure_count: 0
    })
    |> Repo.update()
  end

  @doc """
  Deletes integration rows older than `ttl_minutes` from the given query.
  The query should already include any provider-specific filters that
  identify a "stub" (an integration that never completed setup).
  """
  @spec delete_stubs_older_than(Ecto.Queryable.t(), pos_integer()) ::
          {non_neg_integer(), nil | [term()]}
  def delete_stubs_older_than(query, ttl_minutes) do
    cutoff = DateTime.add(DateTime.utc_now(), -ttl_minutes * 60, :second)

    query
    |> where([i], i.inserted_at < ^cutoff)
    |> Repo.delete_all()
  end

  @doc """
  Returns integrations for `user_id` that are eligible to fire for
  `event_type`: subscribed to the event, currently active, and not
  auto-disabled.

  Provider-specific eligibility filters (e.g. OAuth-pending Slack rows that
  have no `channel_id`, or Telegram rows with no `chat_id`) are intentionally
  not applied here — each provider's queries module layers its own filter on
  top of this result.
  """
  @spec list_active_for_event(module(), integer(), String.t()) :: [Ecto.Schema.t()]
  def list_active_for_event(schema, user_id, event_type) do
    schema
    |> where([i], i.user_id == ^user_id)
    |> where([i], i.is_active == true)
    |> where([i], is_nil(i.disabled_at))
    |> where([i], fragment("? = ANY(?)", ^event_type, i.events))
    |> Repo.all()
  end

  @doc """
  Computes delivery success/failure statistics for an integration's delivery
  rows over the last `days_ago` days. The `delivery_schema` is the
  provider-specific delivery schema module (e.g. `SlackDeliverySchema`).

  All notification provider deliveries share the same outcome shape — a
  `response_status` and an `error_message` — so this aggregate is provider-
  agnostic.

  Returns a map with `:total`, `:successful`, `:failed`, `:success_rate`
  (rounded to one decimal place), and `:period_days`.
  """
  @spec delivery_stats(module(), integer(), pos_integer()) :: %{
          total: non_neg_integer(),
          successful: non_neg_integer(),
          failed: non_neg_integer(),
          success_rate: float(),
          period_days: pos_integer()
        }
  def delivery_stats(delivery_schema, integration_id, days_ago) do
    since = DateTime.add(DateTime.utc_now(), -days_ago, :day)

    %{total: total, successful: successful, failed: failed} =
      Repo.one(
        from d in delivery_schema,
          where: d.integration_id == ^integration_id and d.inserted_at >= ^since,
          select: %{
            total: count(d.id),
            successful: filter(count(d.id), d.response_status >= 200 and d.response_status < 300),
            failed: filter(count(d.id), d.response_status >= 400 or not is_nil(d.error_message))
          }
      )

    %{
      total: total,
      successful: successful,
      failed: failed,
      success_rate: if(total > 0, do: Float.round(successful / total * 100, 1), else: 0.0),
      period_days: days_ago
    }
  end
end
