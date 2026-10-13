function s = formatResult(r)
%FORMATRESULT One-line text of a result, with its method tag.
%
%   s = formatResult(r) returns e.g. "I_on = 518.3 A [Conv: I_L at V_GS 10 %]".
%   The method tag always follows the value, so numbers measured with
%   different conventions are never compared by accident. Flags follow
%   in braces; skipped and failed results show their reason instead.

arguments
    r (1,1) struct
end

if r.status == "ok"
    s = sprintf('%s = %s [%s]', r.symbol, engineering(r.value, r.unit), r.methodTag);
    if ~isempty(r.flags)
        s = sprintf('%s {%s}', s, strjoin(r.flags, ", "));
    end
else
    tag = "";
    if r.methodTag ~= ""
        tag = " [" + r.methodTag + "]";
    end
    s = sprintf('%s: %s%s - %s', r.symbol, upper(r.status), tag, r.reason);
end
s = string(s);

end

% =====================================================================
function s = engineering(value, unit)
% Value with an SI prefix, 4 significant digits.
if ~isfinite(value) || value == 0
    s = sprintf('%.4g %s', value, unit);
    return
end
prefixes = ["p", "n", "u", "m", "", "k", "M", "G"];
exponent = min(max(floor(log10(abs(value)) / 3), -4), 3);
s = sprintf('%.4g %s%s', value / 10^(3 * exponent), prefixes(exponent + 5), unit);
end
