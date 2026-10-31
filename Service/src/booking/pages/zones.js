// What the zone picker searches beyond the zone names: abbreviations, countries and cities that have
// no zone of their own, and the major cities it shows, by offset, before anything is typed. Sent in
// the page's data rather than the script (the script's budget is for code).

export const ALIASES = "America/Los_Angeles:pst pdt pacific la sf san francisco seattle california|America/Denver:mst mdt mountain colorado utah|America/Phoenix:arizona" +
  "|America/Chicago:cst cdt central texas dallas houston austin|America/New_York:est edt eastern nyc ny boston miami washington dc atlanta" +
  "|America/Anchorage:alaska|Pacific/Honolulu:hawaii hst|America/Toronto:canada ontario|America/Mexico_City:mexico|America/Sao_Paulo:brazil brt rio" +
  "|America/Argentina/Buenos_Aires:argentina|America/Bogota:colombia|Europe/London:gmt bst uk britain england scotland wales|Europe/Dublin:ireland" +
  "|Europe/Paris:cet cest france|Europe/Berlin:germany|Europe/Madrid:spain|Europe/Rome:italy|Europe/Amsterdam:netherlands holland|Europe/Zurich:switzerland" +
  "|Europe/Stockholm:sweden|Europe/Warsaw:poland|Europe/Athens:eet eest greece|Europe/Sofia:bulgaria|Europe/Kyiv:ukraine kiev|Europe/Istanbul:turkey" +
  "|Europe/Moscow:russia msk|Asia/Jerusalem:israel|Africa/Cairo:egypt|Africa/Lagos:nigeria wat|Africa/Johannesburg:south africa sast|Africa/Nairobi:kenya eat" +
  "|Asia/Dubai:uae emirates gst|Asia/Karachi:pakistan pkt|Asia/Kolkata:ist india mumbai delhi bangalore bengaluru|Asia/Kathmandu:nepal|Asia/Dhaka:bangladesh" +
  "|Asia/Bangkok:thailand|Asia/Ho_Chi_Minh:vietnam saigon|Asia/Jakarta:indonesia|Asia/Singapore:sgt|Asia/Kuala_Lumpur:malaysia|Asia/Hong_Kong:hk hkt" +
  "|Asia/Shanghai:china beijing|Asia/Taipei:taiwan|Asia/Manila:philippines|Asia/Seoul:korea kst|Asia/Tokyo:japan jst|Australia/Sydney:aest aedt australia nsw" +
  "|Australia/Melbourne:victoria|Australia/Brisbane:queensland|Australia/Perth:awst|Pacific/Auckland:nz new zealand nzst nzdt";

export const MAJOR = ["America/Los_Angeles", "America/Denver", "America/Chicago", "America/New_York", "America/Sao_Paulo", "Europe/London", "Europe/Paris", "Europe/Berlin",
  "Europe/Athens", "Europe/Istanbul", "Asia/Dubai", "Asia/Kolkata", "Asia/Bangkok", "Asia/Singapore", "Asia/Shanghai", "Asia/Tokyo", "Australia/Sydney", "Pacific/Auckland"];
