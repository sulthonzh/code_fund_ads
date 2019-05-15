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

class Campaign < ApplicationRecord
  # extends ...................................................................
  # includes ..................................................................
  include Campaigns::Budgetable
  include Campaigns::Impressionable
  include Campaigns::Operable
  include Campaigns::Presentable
  include Eventable
  include Impressionable
  include Keywordable
  include Organizationable
  include Sparklineable
  include Taggable

  # relationships .............................................................
  belongs_to :creative, -> { includes :creative_images }, optional: true
  belongs_to :user
  has_one :job_posting

  # validations ...............................................................
  validates :name, length: {maximum: 255, allow_blank: false}
  validates :url, presence: true
  validates :status, inclusion: {in: ENUMS::CAMPAIGN_STATUSES.values}

  # callbacks .................................................................
  before_validation :sort_arrays
  before_save :sanitize_assigned_property_ids
  before_save :init_hourly_budget

  # scopes ....................................................................
  scope :pending, -> { where status: ENUMS::CAMPAIGN_STATUSES::PENDING }
  scope :active, -> { where status: ENUMS::CAMPAIGN_STATUSES::ACTIVE }
  scope :archived, -> { where status: ENUMS::CAMPAIGN_STATUSES::ARCHIVED }
  scope :fallback, -> { where fallback: true }
  scope :premium, -> { where fallback: false }
  scope :job_posting, -> { where job_posting: true }
  scope :available_on, ->(date) { where(arel_table[:start_date].lteq(date.to_date)).where(arel_table[:end_date].gteq(date.to_date)) }
  scope :search_keywords, ->(*values) { values.blank? ? all : with_any_keywords(*values) }
  scope :search_country_codes, ->(*values) { values.blank? ? all : with_any_country_codes(*values) }
  scope :search_province_codes, ->(*values) { values.blank? ? all : with_any_province_codes(*values) }
  scope :search_fallback, ->(value) { value.blank? ? all : where(fallback: value) }
  scope :search_name, ->(value) { value.blank? ? all : search_column(:name, value) }
  scope :search_negative_keywords, ->(*values) { values.blank? ? all : with_any_negative(*values) }
  scope :search_status, ->(*values) { values.blank? ? all : where(status: values) }
  scope :search_core_hours_only, ->(value) { value.nil? ? all : where(core_hours_only: value) }
  scope :search_user, ->(value) { value.blank? ? all : where(user_id: User.advertisers.search_name(value).or(User.advertisers.search_company(value))) }
  scope :search_user_id, ->(value) { value.blank? ? all : where(user_id: value) }
  scope :search_weekdays_only, ->(value) { value.nil? ? all : where(weekdays_only: value) }
  scope :without_assigned_property_ids, -> { where assigned_property_ids: [] }
  scope :with_assigned_property_id, ->(property_id) {
    value = Arel::Nodes::SqlLiteral.new(sanitize_sql_array(["ARRAY[?]", property_id]))
    value_cast = Arel::Nodes::NamedFunction.new("CAST", [value.as("bigint[]")])
    where Arel::Nodes::InfixOperation.new("@>", arel_table[:assigned_property_ids], value_cast)
  }
  scope :premium_with_assigned_property_id, ->(property_id) { premium.with_assigned_property_id property_id }
  scope :fallback_with_assigned_property_id, ->(property_id) { fallback.with_assigned_property_id property_id }
  scope :permitted_for_property_id, ->(property_id) {
    subquery = Property.select(:prohibited_advertiser_ids).where(id: property_id)
    id_prohibited = Arel::Nodes::InfixOperation.new("<@", Arel::Nodes::SqlLiteral.new("ARRAY[\"campaigns\".\"user_id\"]"), subquery.arel)
    where.not id_prohibited
  }
  scope :targeted_premium_for_property, ->(property, *keywords) { targeted_premium_for_property_id property.id }
  scope :targeted_premium_for_property_id, ->(property_id, *keywords) { premium.targeted_for_property_id(property_id, *keywords) }
  scope :targeted_for_property_id, ->(property_id, *keywords) do
    if keywords.present?
      permitted_for_property_id(property_id)
        .with_any_keywords(*keywords)
        .without_any_negative_keywords(*keywords)
        .without_assigned_property_ids
    else
      subquery = Property.active.select(:keywords).where(id: property_id)
      keywords_overlap = Arel::Nodes::InfixOperation.new("&&", arel_table[:keywords], subquery.arel)
      negative_keywords_overlap = Arel::Nodes::InfixOperation.new("&&", arel_table[:negative_keywords], subquery.arel)
      permitted_for_property_id(property_id)
        .where(keywords_overlap)
        .where.not(negative_keywords_overlap)
        .without_assigned_property_ids
    end
  end
  scope :fallback_for_property_id, ->(property_id) do
    fallback
      .permitted_for_property_id(property_id)
      .where.not(fallback: Property.select(:prohibit_fallback_campaigns).where(id: property_id).limit(1))
  end
  scope :targeted_fallback_for_property_id, ->(property_id, *keywords) do
    fallback
      .targeted_for_property_id(property_id, *keywords)
      .where.not(fallback: Property.select(:prohibit_fallback_campaigns).where(id: property_id).limit(1))
  end
  scope :targeted_country_code, ->(country_code) { country_code ? with_all_country_codes(country_code) : without_country_codes }
  scope :targeted_province_code, ->(province_code) { province_code ? without_province_codes.or(with_all_province_codes(province_code)) : without_province_codes }

  # Scopes and helpers provied by tag_columns
  # SEE: https://github.com/hopsoft/tag_columns
  #
  # - with_country_codes
  # - without_country_codes
  # - with_any_country_codes
  # - without_any_country_codes
  # - with_all_country_codes
  # - without_all_country_codes
  #
  # - with_province_codes
  # - without_province_codes
  # - with_any_province_codes
  # - without_any_province_codes
  # - with_all_province_codes
  # - without_all_province_codes
  #
  # - with_keywords
  # - without_keywords
  # - with_any_keywords
  # - without_any_keywords
  # - with_all_keywords
  # - without_all_keywords
  #
  # - with_negative_keywords
  # - without_negative_keywords
  # - with_any_negative_keywords
  # - without_any_negative_keywords
  # - with_all_negative_keywords
  # - without_all_negative_keywords
  #
  # Examples
  #
  #   irb>Campaign.with_country_codes("US", "GB")
  #   irb>Campaign.with_keywords("Frontend Frameworks & Tools", "Ruby")
  #   irb>Campaign.without_negative_keywords("Database", "Docker", "React")

  # additional config (i.e. accepts_nested_attribute_for etc...) ..............
  monetize :total_budget_cents, numericality: {greater_than_or_equal_to: 0}
  monetize :daily_budget_cents, numericality: {greater_than_or_equal_to: 0}
  monetize :hourly_budget_cents, numericality: {greater_than_or_equal_to: 0}
  monetize :ecpm_cents, numericality: {greater_than_or_equal_to: 0}
  tag_columns :country_codes
  tag_columns :province_codes
  tag_columns :keywords
  tag_columns :negative_keywords
  acts_as_commentable
  has_paper_trail on: %i[create update destroy], version_limit: nil, only: %i[
    core_hours_only
    country_codes
    creative_id
    daily_budget_cents
    daily_budget_currency
    ecpm_cents
    ecpm_currency
    end_date
    keywords
    name
    negative_keywords
    province_codes
    start_date
    status
    total_budget_cents
    total_budget_currency
    url
    user_id
    weekdays_only
  ]

  # class methods .............................................................
  class << self
  end

  # public instance methods ...................................................

  def assigner_properties
    return Property.none unless fallback?
    Property.with_assigned_fallback_campaign_id id
  end

  def assigned_properties
    return Property.none if assigned_property_ids.blank?
    Property.where id: assigned_property_ids
  end

  def adjusted_ecpm(country_code)
    return ecpm if fixed_ecpm?

    adjusted = ecpm * Country::UNKNOWN_CPM_MULTIPLER
    country = Country.find(country_code)
    if country
      # TODO: delete logic for country multiplier after all campaigns with a start_date before 2019-03-07 have completed
      adjusted = if start_date && start_date < Date.parse("2019-03-07")
        country.ecpm base: ecpm, multiplier: :country
      else
        country.ecpm base: ecpm
      end
    end
    adjusted = Monetize.parse("$0.10 USD") if adjusted.cents < 10
    adjusted
  end

  def ecpms
    countries.map do |country|
      {
        country_iso_code: country.iso_code,
        country_name: country.name,
        ecpm: adjusted_ecpm(country.iso_code),
      }
    end
  end

  # Returns a relation for properties that have rendered this campaign
  def properties(start_date = nil, end_date = nil)
    subquery = impressions.between(start_date, end_date).distinct(:property_id).select(:property_id) if start_date
    subquery ||= impressions.distinct(:property_id).select(:property_id)
    Property.where id: subquery
  end

  # Returns a relation for properties that have produced a click for this campaign
  def properties_with_clicks(start_date = nil, end_date = nil)
    subquery = impressions.clicked.between(start_date, end_date).distinct(:property_id).select(:property_id) if start_date
    subquery ||= impressions.clicked.distinct(:property_id).select(:property_id)
    Property.where id: subquery
  end

  def matching_properties
    Property.for_campaign self
  end

  def matching_keywords(property)
    keywords & property.keywords
  end

  def pending?
    status == ENUMS::CAMPAIGN_STATUSES::PENDING
  end

  def active?
    status == ENUMS::CAMPAIGN_STATUSES::ACTIVE
  end

  def archived?
    status == ENUMS::CAMPAIGN_STATUSES::ARCHIVED
  end

  def premium?
    !fallback?
  end

  def available_on?(date)
    date.to_date.between? start_date, end_date
  end

  def date_range
    return nil unless start_date && end_date
    "#{start_date.to_s "mm/dd/yyyy"} #{end_date.to_s "mm/dd/yyyy"}"
  end

  def date_range=(value)
    dates = value.split(" - ")
    self.start_date = Date.strptime(dates[0], "%m/%d/%Y")
    self.end_date   = Date.strptime(dates[1], "%m/%d/%Y")
  end

  def countries
    Country.where iso_code: country_codes
  end

  def provinces
    Province.where iso_code: province_codes
  end

  def campaign_type
    return "fallback" if fallback?
    "premium"
  end

  def to_meta_tags
    {
      title: name,
      keywords: keywords,
    }
  end

  # protected instance methods ................................................

  # private instance methods ..................................................

  private

  def sort_arrays
    self.country_codes = country_codes&.reject(&:blank?)&.sort || []
    self.keywords = keywords&.reject(&:blank?)&.sort || []
    self.negative_keywords = negative_keywords&.reject(&:blank?)&.sort || []
    self.province_codes = province_codes&.reject(&:blank?)&.sort
  end

  def sanitize_assigned_property_ids
    self.assigned_property_ids = assigned_property_ids.select(&:present?).uniq.sort
  end

  def init_hourly_budget
    min = Monetize.parse("$0.10 USD")
    return if hourly_budget >= min
    return unless daily_budget > 0
    self.hourly_budget = daily_budget / 12
    self.hourly_budget = min if hourly_budget < min
  end
end
