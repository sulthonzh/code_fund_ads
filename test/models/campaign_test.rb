# == Schema Information
#
# Table name: campaigns
#
#  id                     :bigint(8)        not null, primary key
#  user_id                :bigint(8)
#  creative_id            :bigint(8)
#  status                 :string           not null
#  fallback               :boolean          default(FALSE), not null
#  name                   :string           not null
#  url                    :text             not null
#  start_date             :date
#  end_date               :date
#  core_hours_only        :boolean          default(FALSE)
#  weekdays_only          :boolean          default(FALSE)
#  total_budget_cents     :integer          default(0), not null
#  total_budget_currency  :string           default("USD"), not null
#  daily_budget_cents     :integer          default(0), not null
#  daily_budget_currency  :string           default("USD"), not null
#  ecpm_cents             :integer          default(0), not null
#  ecpm_currency          :string           default("USD"), not null
#  country_codes          :string           default([]), is an Array
#  keywords               :string           default([]), is an Array
#  negative_keywords      :string           default([]), is an Array
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  legacy_id              :uuid
#  organization_id        :bigint(8)
#  job_posting            :boolean          default(FALSE), not null
#  province_codes         :string           default([]), is an Array
#  fixed_ecpm             :boolean          default(TRUE), not null
#  assigned_property_ids  :bigint(8)        default([]), not null, is an Array
#  hourly_budget_cents    :integer          default(0), not null
#  hourly_budget_currency :string           default("USD"), not null
#

require "test_helper"

class CampaignTest < ActiveSupport::TestCase
  setup do
    @campaign = campaigns(:premium)
    @campaign.start_date = Date.parse("2019-01-01")
    @campaign.end_date = @campaign.start_date.advance(months: 3)
    @campaign.organization.update balance: Monetize.parse("$10,000 USD")
    travel_to @campaign.start_date.to_time.advance(days: 15)
  end

  teardown do
    travel_back
  end

  test "initial campaign budgets" do
    assert @campaign.total_budget == Monetize.parse("$5,000.00 USD")
    assert @campaign.ecpm == Monetize.parse("$3.00 USD")
    assert @campaign.total_consumed_budget == Monetize.parse("$0.00 USD")
    assert @campaign.total_remaining_budget == @campaign.total_budget
    assert @campaign.total_operative_days == 91
  end

  test "restricting to weekdays impacts the numbers" do
    @campaign.update weekdays_only: true
    assert @campaign.total_operative_days == 65
  end

  test "increasing ecpm up impacts the numbers" do
    @campaign.update ecpm: Monetize.parse("$4.00 USD")
  end

  test "decreasing ecpm down impacts the numbers" do
    @campaign.update ecpm: Monetize.parse("$2.00 USD")
  end

  test "increasing total_budget impacts the numbers" do
    @campaign.update total_budget: Monetize.parse("$8,000.00 USD")
  end

  test "decreasing daily_budget yields a budget surplus" do
    @campaign.update daily_budget: Monetize.parse("$20.00 USD")
  end

  test "ecpms fixed" do
    @campaign.fixed_ecpm = true
    assert @campaign.ecpm == Monetize.parse("$3.00 USD")
    assert @campaign.ecpms == [
      {country_iso_code: "GB", country_name: "United Kingdom of Great Britain and Northern Ireland", ecpm: Monetize.parse("$3.00 USD")},
      {country_iso_code: "US", country_name: "United States of America", ecpm: Monetize.parse("$3.00 USD")},
      {country_iso_code: "CA", country_name: "Canada", ecpm: Monetize.parse("$3.00 USD")},
      {country_iso_code: "JP", country_name: "Japan", ecpm: Monetize.parse("$3.00 USD")},
      {country_iso_code: "RO", country_name: "Romania", ecpm: Monetize.parse("$3.00 USD")},
      {country_iso_code: "FR", country_name: "France", ecpm: Monetize.parse("$3.00 USD")},
      {country_iso_code: "IN", country_name: "India", ecpm: Monetize.parse("$3.00 USD")},
    ]
  end

  test "ecpms old pricing based on start_date before 2019-03-07" do
    @campaign.fixed_ecpm = false
    @campaign.start_date = Date.parse("2019-03-06")
    @campaign.end_date = @campaign.start_date.advance(months: 1)
    assert @campaign.ecpm == Monetize.parse("$3.00 USD")

    assert @campaign.ecpms == [
      {country_iso_code: "GB", country_name: "United Kingdom of Great Britain and Northern Ireland", ecpm: Monetize.parse("$2.61 USD")},
      {country_iso_code: "US", country_name: "United States of America", ecpm: Monetize.parse("$3.00 USD")},
      {country_iso_code: "CA", country_name: "Canada", ecpm: Monetize.parse("$2.13 USD")},
      {country_iso_code: "JP", country_name: "Japan", ecpm: Monetize.parse("$1.59 USD")},
      {country_iso_code: "RO", country_name: "Romania", ecpm: Monetize.parse("$0.93 USD")},
      {country_iso_code: "FR", country_name: "France", ecpm: Monetize.parse("$1.08 USD")},
      {country_iso_code: "IN", country_name: "India", ecpm: Monetize.parse("$0.69 USD")},
    ]
  end

  test "ecpms new pricing based on start_date after 2019-03-07" do
    @campaign.fixed_ecpm = false
    @campaign.start_date = Date.parse("2019-03-07")
    @campaign.end_date = @campaign.start_date.advance(months: 1)
    assert @campaign.ecpm == Monetize.parse("$3.00 USD")
    assert @campaign.ecpms == [
      {country_iso_code: "GB", country_name: "United Kingdom of Great Britain and Northern Ireland", ecpm: Monetize.parse("$2.40 USD")},
      {country_iso_code: "US", country_name: "United States of America", ecpm: Monetize.parse("$3.00 USD")},
      {country_iso_code: "CA", country_name: "Canada", ecpm: Monetize.parse("$3.00 USD")},
      {country_iso_code: "JP", country_name: "Japan", ecpm: Monetize.parse("$0.30 USD")},
      {country_iso_code: "RO", country_name: "Romania", ecpm: Monetize.parse("$0.90 USD")},
      {country_iso_code: "FR", country_name: "France", ecpm: Monetize.parse("$2.40 USD")},
      {country_iso_code: "IN", country_name: "India", ecpm: Monetize.parse("$0.30 USD")},
    ]
  end
end
