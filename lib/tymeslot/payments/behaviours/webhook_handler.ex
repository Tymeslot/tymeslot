defmodule Tymeslot.Payments.Behaviours.WebhookHandler do
  @moduledoc """
  Behaviour for Stripe webhook event handlers.

  Implement this behaviour for each type of webhook event that needs processing.
  """

  @type event :: map()
  @type object :: map()
  @type result :: {:ok, atom()} | {:error, atom() | Exception.t(), String.t() | nil}

  @doc """
  Processes a webhook event of a specific type.

  Returns a standardized result tuple with a status atom indicating success or failure.
  """
  @callback process(event(), object()) :: result()

  @doc """
  Returns whether this handler can process the given event type.

  Used by the registry to determine which handler to use.
  """
  @callback can_handle?(String.t()) :: boolean()

  @doc """
  Validates that the webhook object contains all required fields for processing.

  Returns :ok if valid, or {:error, reason} if invalid.
  """
  @callback validate(object()) :: :ok | {:error, atom(), String.t()}

  @doc """
  Validates that the webhook object contains all required fields for processing.

  Accepts the event type to allow conditional validation per event.
  """
  @callback validate(String.t(), object()) :: :ok | {:error, atom(), String.t()}

  @optional_callbacks [validate: 1, validate: 2]

  @doc """
  Injects default `validate/1` and `validate/2` implementations.

  The defaults return `:ok` for `validate/1` and delegate `validate/2`
  to `validate/1`. Override `validate/1` for simple validation, or
  `validate/2` when event-type-specific logic is needed.

  If you override both, ensure the delegation direction is consistent
  (see `InvoiceHandler` for an example that reverses the default direction).
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Tymeslot.Payments.Behaviours.WebhookHandler

      @impl Tymeslot.Payments.Behaviours.WebhookHandler
      def validate(_object), do: :ok

      @impl Tymeslot.Payments.Behaviours.WebhookHandler
      def validate(_event_type, object), do: validate(object)

      defoverridable validate: 1, validate: 2
    end
  end
end
