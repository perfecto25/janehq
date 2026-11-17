module JaneHQ
  module Web
    # Date range choices for the metrics page (label, days ending at the picked date).
    METRIC_RANGES = [{1, "1 day"}, {7, "7 days"}, {30, "30 days"}, {90, "90 days"}]

    # Inline-SVG line chart over [from, to]: a filled average line, an optional
    # fainter peak line, y axis 0..ymax. Gaps (host offline) are left as gaps.
    def self.metric_chart(points : Array(MetricPoint), from : Int64, to : Int64,
                          lines : Array({String, String, Proc(MetricPoint, Float64?)}),
                          ymax : Float64, unit : String, gap : Int64) : String
      w, h = 900, 220
      l, r, t, b = 44, 12, 10, 26
      pw, ph = (w - l - r).to_f, (h - t - b).to_f
      span = {(to - from).to_f, 1.0}.max
      x = ->(ts : Int64) { l + (ts - from) / span * pw }
      y = ->(v : Float64) { t + ph - ({v, ymax}.min / ymax) * ph }
      fmt = ->(v : Float64) { v.round(1).to_s }

      String.build do |s|
        s << %(<svg class="chart" viewBox="0 0 #{w} #{h}" role="img" preserveAspectRatio="none">)
        4.times do |i|
          v = ymax * i / 3
          yy = y.call(v)
          s << %(<line x1="#{l}" x2="#{w - r}" y1="#{fmt.call(yy)}" y2="#{fmt.call(yy)}" class="grid"/>)
          s << %(<text x="#{l - 6}" y="#{fmt.call(yy + 4)}" class="axis" text-anchor="end">#{fmt.call(v)}#{unit}</text>)
        end
        ticks = 5
        ticks.times do |i|
          ts = from + ((to - from) * i // (ticks - 1))
          anchor = i == 0 ? "start" : (i == ticks - 1 ? "end" : "middle")
          fmt_t = (to - from) <= 2 * 86_400 ? "%H:%M" : "%b %-d"
          s << %(<text x="#{fmt.call(x.call(ts))}" y="#{h - 8}" class="axis" text-anchor="#{anchor}">#{Time.unix(ts).to_utc.to_s(fmt_t)}</text>)
        end
        lines.each do |(cls, _label, getter)|
          d = String.build do |p|
            prev = nil.as(Int64?)
            points.each do |pt|
              v = getter.call(pt)
              next unless v
              cmd = prev && pt.ts - prev <= gap ? "L" : "M"
              p << cmd << fmt.call(x.call(pt.ts)) << ' ' << fmt.call(y.call(v)) << ' '
              prev = pt.ts
            end
          end
          s << %(<path d="#{d}" class="line #{cls}"/>) unless points.empty?
        end
        s << "</svg>"
      end
    end

    # One mount as reported by the agent. `pct` is set when the agent's usage
    # check is percent-based; byte-based checks only carry the used size.
    record Mount, name : String, status : String, current : String, threshold : String,
      message : String, pct : Float64?

    # The agent has no mount list in its metrics: each monitored filesystem
    # arrives as a "Filesystem <name>" check (plus "Filesystem <name> inode ..."
    # rule checks, which are not usage and are skipped here).
    def self.mounts(checks : Array(CheckRecord)) : Array(Mount)
      checks.compact_map do |c|
        next unless m = c.name.match(/\AFilesystem (\S+)\z/)
        pct = c.current.ends_with?('%') ? c.current.chomp('%').to_f? : nil
        Mount.new(m[1], c.status, c.current, c.threshold, c.message, pct)
      end.sort_by(&.name.downcase)
    end

    def self.fmt_bytes(b : Int64 | Float64) : String
      v = b.to_f
      units = %w(B KB MB GB TB)
      i = 0
      while v >= 1024 && i < units.size - 1
        v /= 1024
        i += 1
      end
      i == 0 ? "#{v.round.to_i} B" : "#{v.round(i >= 3 ? 2 : 1)} #{units[i]}"
    end

    def self.fmt_rate(bps : Float64?) : String
      bps ? "#{fmt_bytes(bps)}/s" : "–"
    end

    def self.define_metrics_routes
      get "/metrics" do |env|
        agents = storage.all_agents.sort_by(&.hostname.downcase)
        agent = env.params.query["host"]?.try { |hn| agents.find { |a| a.hostname == hn } }
        now = Time.utc.to_unix
        today = Time.unix(now).to_utc.at_beginning_of_day
        date = env.params.query["date"]?.try { |d| Time.parse_utc(d, "%Y-%m-%d") rescue nil } || today
        date = today if date > today
        range = (env.params.query["range"]?.try &.to_i? || 1)
        range = 1 unless METRIC_RANGES.any? { |(d, _)| d == range }
        date_s = date.to_s("%Y-%m-%d")
        today_s = today.to_s("%Y-%m-%d")
        to = {(date + 1.day).to_unix - 1, now}.min
        from = (date + 1.day).to_unix - range.to_i64 * 86_400
        mounts = agent ? mounts(storage.checks_for(agent.id)) : [] of Mount
        # Top processes: the live snapshot for today, else the stored one nearest
        # before the chosen time (`at`, HH:MM UTC; default end of the chosen day).
        at_s = env.params.query["at"]?.try(&.strip) || ""
        at_t = at_s.empty? ? nil : (Time.parse_utc(at_s, "%H:%M") rescue nil)
        procs_at_ts = at_t ? date.to_unix + at_t.hour * 3600 + at_t.minute * 60 : to
        procs = if agent.nil?
                  nil
                elsif at_t.nil? && date == today
                  storage.top_procs_for(agent.id)
                else
                  storage.top_procs_at(agent.id, {procs_at_ts, now}.min)
                end
        points = agent ? storage.metric_series(agent.id, from, to, now: now) : [] of MetricPoint
        render "src/web/views/metrics.ecr", "src/web/views/layout.ecr"
      end
    end
  end
end
