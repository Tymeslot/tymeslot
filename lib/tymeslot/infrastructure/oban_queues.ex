defmodule Tymeslot.Infrastructure.ObanQueues do
  @moduledoc """
  Builds the `:queues` section of the Oban configuration.

  Core declares its queues under `:oban_queues`; wrapper applications extend or
  override them through the `:oban_additional_queues` extension point. Both are
  read at runtime rather than at config time, because Oban's configuration
  function runs after all config files have been applied.

  Queue concurrency is validated against the database connection pool size, but
  only when the queues will actually run. In Oban's `:manual` and `:inline`
  testing modes the queue list is discarded outright (see `Oban.Config`), so
  the declared concurrency consumes no connections and must not be allowed to
  abort application startup.
  """

  require Logger

  alias Tymeslot.Repo

  @default_pool_size 10
  @high_concurrency 100

  @typedoc "Oban's testing mode, as carried by the Oban config"
  @type testing_mode :: :disabled | :manual | :inline

  @typedoc "Pool ceiling applied to queue concurrency, or `:unlimited` when no queue runs"
  @type pool_limit :: pos_integer() | :unlimited

  @doc """
  Returns `base_config` with a validated, merged `:queues` list.

  `base_config` is the application's Oban configuration; its `:testing` key
  determines whether queue concurrency is checked against the pool size.
  """
  @spec build(keyword()) :: keyword()
  def build(base_config) do
    queues =
      merge(
        Application.get_env(:tymeslot, :oban_queues, []),
        Application.get_env(:tymeslot, :oban_additional_queues, []),
        pool_size: pool_size(),
        testing: Keyword.get(base_config, :testing, :disabled)
      )

    Keyword.put(base_config, :queues, queues)
  end

  @doc """
  Validates both queue lists and merges them, with `additional_queues` winning
  on conflicts.

  Options:

    * `:pool_size` — connection pool to validate concurrency against; defaults
      to the configured `Tymeslot.Repo` pool size
    * `:testing` — Oban testing mode; `:manual` and `:inline` skip the pool
      check, since Oban drops the queues in those modes

  Raises `ArgumentError` for a malformed queue list, a non-integer or
  non-positive concurrency, or (outside testing modes) a concurrency above the
  pool size.
  """
  @spec merge(term(), term(), keyword()) :: keyword()
  def merge(base_queues, additional_queues, opts \\ []) do
    validate_keyword!(base_queues, :oban_queues)
    validate_keyword!(additional_queues, :oban_additional_queues)

    log_overrides(base_queues, additional_queues)

    limit = pool_limit(opts)
    validate_concurrency!(base_queues, "base", limit)
    validate_concurrency!(additional_queues, "additional", limit)

    case Keyword.merge(base_queues, additional_queues) do
      [] ->
        Logger.error("No Oban queues configured, using minimal default")
        [default: 1]

      merged ->
        merged
    end
  end

  @spec validate_keyword!(term(), atom()) :: :ok
  defp validate_keyword!(queues, key) do
    unless Keyword.keyword?(queues) do
      raise ArgumentError, ":#{key} must be a keyword list, got: #{inspect(queues)}"
    end

    :ok
  end

  @spec log_overrides(keyword(), keyword()) :: :ok
  defp log_overrides(base_queues, additional_queues) do
    base_keys = Keyword.keys(base_queues)

    case Enum.filter(Keyword.keys(additional_queues), &(&1 in base_keys)) do
      [] ->
        :ok

      conflicts ->
        Logger.info("Additional queues overriding Core queue concurrency", queues: conflicts)
    end

    :ok
  end

  @spec validate_concurrency!(keyword(), String.t(), pool_limit()) :: :ok
  defp validate_concurrency!(queues, source, limit) do
    Enum.each(queues, fn {queue, concurrency} ->
      cond do
        not is_integer(concurrency) ->
          raise ArgumentError,
                "Invalid concurrency for queue #{queue} in #{source} queues: " <>
                  "#{inspect(concurrency)} (must be an integer)"

        concurrency <= 0 ->
          raise ArgumentError,
                "Invalid concurrency for queue #{queue} in #{source} queues: " <>
                  "#{concurrency} (must be positive)"

        exceeds_pool?(concurrency, limit) ->
          raise ArgumentError,
                "Queue #{queue} concurrency (#{concurrency}) exceeds pool_size (#{limit}). " <>
                  "Queue concurrency cannot be higher than the database connection pool size."

        concurrency >= @high_concurrency ->
          Logger.warning(
            "Very high concurrency for queue #{queue} in #{source} queues: #{concurrency}. " <>
              "Ensure this is intentional and pool_size can support it.",
            queue: queue,
            concurrency: concurrency,
            pool_size: limit,
            source: source
          )

        true ->
          :ok
      end
    end)

    :ok
  end

  @spec exceeds_pool?(integer(), pool_limit()) :: boolean()
  defp exceeds_pool?(_concurrency, :unlimited), do: false
  defp exceeds_pool?(concurrency, pool_size), do: concurrency > pool_size

  @spec pool_limit(keyword()) :: pool_limit()
  defp pool_limit(opts) do
    case Keyword.get(opts, :testing, :disabled) do
      mode when mode in [:manual, :inline] -> :unlimited
      _disabled -> Keyword.get_lazy(opts, :pool_size, &pool_size/0)
    end
  end

  @spec pool_size() :: pos_integer()
  defp pool_size do
    :tymeslot
    |> Application.get_env(Repo, [])
    |> Keyword.get(:pool_size, @default_pool_size)
  end
end
