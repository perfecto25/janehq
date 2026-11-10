module JaneHQ
  # Human "time since" for the Last seen columns: seconds up to a minute, then
  # minutes, hours+minutes, and days+hours+minutes (e.g. "2 days 12 hours 30 min").
  def self.ago(seconds : Int) : String
    s = seconds < 0 ? 0_i64 : seconds.to_i64
    return "#{s}s" if s <= 60
    mins = s // 60
    return "#{mins} min" if mins < 60
    hours, m = mins.divmod(60)
    if hours < 24
      return m.zero? ? "#{hours} #{hours == 1 ? "hour" : "hours"}" : "#{hours} #{hours == 1 ? "hour" : "hours"} #{m} min"
    end
    days, h = hours.divmod(24)
    parts = ["#{days} #{days == 1 ? "day" : "days"}"]
    parts << "#{h} #{h == 1 ? "hour" : "hours"}" if h > 0
    parts << "#{m} min" if m > 0
    parts.join(" ")
  end
end
