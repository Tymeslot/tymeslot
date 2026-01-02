defmodule Tymeslot.Pagination.CursorPage do
  @moduledoc """
  Generic cursor page response for keyset pagination.

  Cursors are encoded as a URL-safe base64 JSON string. Helpers are provided to
  encode/decode a map containing :after_start and :after_id for meeting pagination.
  """

  @enforce_keys [:items]
  defstruct items: [], next_cursor: nil, prev_cursor: nil, page_size: nil, has_more: false

  @type t(item) :: %__MODULE__{
          items: [item],
          next_cursor: String.t() | nil,
          prev_cursor: String.t() | nil,
          page_size: pos_integer() | nil,
          has_more: boolean()
        }
  @type t :: t(map())

  @doc """
  Encodes a cursor map like %{after_start: DateTime.t(), after_id: binary()} to a URL-safe string.
  """
  @spec encode_cursor(%{after_start: DateTime.t(), after_id: binary()}) :: String.t()
  def encode_cursor(%{after_start: %DateTime{} = after_start, after_id: after_id})
      when is_binary(after_id) do
    payload = %{after_start: DateTime.to_iso8601(after_start), after_id: after_id}
    Base.url_encode64(Jason.encode!(payload), padding: false)
  end

  @doc """
  Decodes a cursor string back into a map %{after_start: DateTime.t(), after_id: binary()}.
  Returns {:ok, map} | {:error, reason}.
  """
  @spec decode_cursor(String.t()) ::
          {:ok, %{after_start: DateTime.t(), after_id: binary()}} | {:error, term()}
  def decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"after_start" => after_start_str, "after_id" => after_id}} <- Jason.decode(json),
         {:ok, after_start, _} <- DateTime.from_iso8601(after_start_str) do
      {:ok, %{after_start: after_start, after_id: after_id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end
end
