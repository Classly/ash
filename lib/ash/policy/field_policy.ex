defmodule Ash.Policy.FieldPolicy do
  @moduledoc false
  defstruct [
    :fields,
    :condition,
    :policies,
    :description,
    :__identifier__,
    bypass?: false
  ]

  @type t :: %__MODULE__{}

  @doc false
  def transform(field_policy) do
    if Enum.empty?(field_policy.policies) do
      {:error, "Field policies must have at least one check."}
    else
      {:ok,
       %{
         field_policy
         | policies: Enum.map(field_policy.policies, &set_field_policy_opt/1),
           condition: field_policy.condition || []
       }}
    end
  end

  defp set_field_policy_opt(%{check_opts: opts} = policy) do
    %{policy | check_opts: Keyword.merge(opts, ash_field_policy?: true, access_type: :filter)}
  end
end
