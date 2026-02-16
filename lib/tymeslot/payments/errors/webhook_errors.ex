defmodule Tymeslot.Payments.Errors.WebhookError do
  @moduledoc """
  Error structs for webhook processing.
  """

  @type t ::
          __MODULE__.SignatureError.t()
          | __MODULE__.ValidationError.t()
          | __MODULE__.ProcessingError.t()

  defmodule SignatureError do
    @moduledoc "Error raised when webhook signature validation fails"
    @type t :: %__MODULE__{
            message: String.t(),
            reason: atom(),
            details: map() | nil
          }
    defexception [:message, :reason, :details]

    @impl Exception
    def message(%__MODULE__{message: message}), do: message
  end

  defmodule ValidationError do
    @moduledoc "Error raised when webhook payload is invalid"
    @type t :: %__MODULE__{
            message: String.t(),
            reason: atom(),
            details: map() | nil
          }
    defexception [:message, :reason, :details]

    @impl Exception
    def message(%__MODULE__{message: message}), do: message
  end

  defmodule ProcessingError do
    @moduledoc "Error raised when webhook processing fails"
    @type t :: %__MODULE__{
            message: String.t(),
            reason: atom(),
            event_type: String.t() | nil,
            details: map() | nil
          }
    defexception [:message, :reason, :event_type, :details]

    @impl Exception
    def message(%__MODULE__{message: message}), do: message
  end
end
