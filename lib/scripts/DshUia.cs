using System;
using System.Collections.Generic;
using System.Windows.Automation;

// UI Automation access: find controls by name, invoke them without a single mouse event.
// Works for Win32 / WinForms / WPF / UWP apps. CEF apps (bilibili client, Electron) usually
// expose nothing here, which is exactly why gui-ocr.ps1 exists as the fallback.
// ASCII only.
public static class DshUia
{
    public static AutomationElement FindWindow(string titleContains)
    {
        var root = AutomationElement.RootElement;
        if (root == null) return null;
        var exact = new PropertyCondition(AutomationElement.NameProperty, titleContains);
        var w = root.FindFirst(TreeScope.Children, exact);
        if (w != null) return w;

        var kids = root.FindAll(TreeScope.Children, Condition.TrueCondition);
        foreach (AutomationElement e in kids)
        {
            try
            {
                string n = e.Current.Name;
                if (!string.IsNullOrEmpty(n) && n.IndexOf(titleContains, StringComparison.OrdinalIgnoreCase) >= 0) return e;
            }
            catch { }
        }
        return null;
    }

    // Substring match on the accessible Name, optionally limited to one control type
    // (e.g. "Button"), which also keeps the search fast on large trees.
    public static List<AutomationElement> Find(AutomationElement scope, string contains, string controlType, int max)
    {
        var res = new List<AutomationElement>();
        if (scope == null) return res;
        Condition cond = Condition.TrueCondition;
        if (!string.IsNullOrEmpty(controlType))
        {
            ControlType ct = null;
            switch (controlType.ToLower())
            {
                case "button": ct = ControlType.Button; break;
                case "edit": ct = ControlType.Edit; break;
                case "text": ct = ControlType.Text; break;
                case "listitem": ct = ControlType.ListItem; break;
                case "tabitem": ct = ControlType.TabItem; break;
                case "menuitem": ct = ControlType.MenuItem; break;
                case "checkbox": ct = ControlType.CheckBox; break;
                case "radiobutton": ct = ControlType.RadioButton; break;
                case "combobox": ct = ControlType.ComboBox; break;
                case "hyperlink": ct = ControlType.Hyperlink; break;
                case "treeitem": ct = ControlType.TreeItem; break;
                case "dataitem": ct = ControlType.DataItem; break;
                case "image": ct = ControlType.Image; break;
                case "group": ct = ControlType.Group; break;
            }
            if (ct != null) cond = new PropertyCondition(AutomationElement.ControlTypeProperty, ct);
        }
        AutomationElementCollection all;
        try { all = scope.FindAll(TreeScope.Descendants, cond); }
        catch { return res; }
        foreach (AutomationElement e in all)
        {
            if (res.Count >= max) break;
            try
            {
                string n = e.Current.Name;
                if (!string.IsNullOrEmpty(n) && n.IndexOf(contains, StringComparison.OrdinalIgnoreCase) >= 0) res.Add(e);
            }
            catch { }
        }
        return res;
    }

    public static string Name(AutomationElement e) { try { return e.Current.Name; } catch { return ""; } }
    public static string AutoId(AutomationElement e) { try { return e.Current.AutomationId; } catch { return ""; } }
    public static bool IsPassword(AutomationElement e) { try { return e.Current.IsPassword; } catch { return false; } }

    public static string Value(AutomationElement e)
    {
        try
        {
            object p;
            if (e.TryGetCurrentPattern(ValuePattern.Pattern, out p))
                return ((ValuePattern)p).Current.Value;
            return "";
        }
        catch { return ""; }
    }

    public static string ClassOf(AutomationElement e) { try { return e.Current.ClassName; } catch { return ""; } }
    public static string TypeOf(AutomationElement e) { try { return e.Current.ControlType.ProgrammaticName.Replace("ControlType.", ""); } catch { return ""; } }

    public static double[] Rect(AutomationElement e)
    {
        // Off-screen / collapsed elements report +/-Infinity here, which cannot be cast to
        // int. Clamp to -1 so callers can treat them as "no usable rectangle".
        try
        {
            var r = e.Current.BoundingRectangle;
            double x = r.X, y = r.Y, w = r.Width, h = r.Height;
            if (double.IsNaN(x) || double.IsInfinity(x)) { x = -1; w = 0; }
            if (double.IsNaN(y) || double.IsInfinity(y)) { y = -1; h = 0; }
            if (double.IsNaN(w) || double.IsInfinity(w)) { w = 0; }
            if (double.IsNaN(h) || double.IsInfinity(h)) { h = 0; }
            if (x < -10000 || y < -10000) { return new double[] { -1, -1, 0, 0 }; }
            return new double[] { x, y, w, h };
        }
        catch { return new double[] { -1, -1, 0, 0 }; }
    }

    // Prefer the accessibility action over simulating a click: works even when the window
    // is behind another window, and cannot miss by a few pixels.
    public static string Activate(AutomationElement e)
    {
        object p;
        try
        {
            if (e.TryGetCurrentPattern(InvokePattern.Pattern, out p))
            {
                ((InvokePattern)p).Invoke();
                return "invoke";
            }
            if (e.TryGetCurrentPattern(SelectionItemPattern.Pattern, out p))
            {
                ((SelectionItemPattern)p).Select();
                return "select";
            }
            if (e.TryGetCurrentPattern(TogglePattern.Pattern, out p))
            {
                ((TogglePattern)p).Toggle();
                return "toggle";
            }
        }
        catch (Exception ex) { return "error:" + ex.Message; }
        return "none";
    }

    public static string SetText(AutomationElement e, string value)
    {
        object p;
        try
        {
            if (e.TryGetCurrentPattern(ValuePattern.Pattern, out p))
            {
                ((ValuePattern)p).SetValue(value);
                return "value";
            }
        }
        catch (Exception ex) { return "error:" + ex.Message; }
        return "none";
    }

    public static string GetText(AutomationElement e)
    {
        object p;
        try
        {
            if (e.TryGetCurrentPattern(ValuePattern.Pattern, out p)) return ((ValuePattern)p).Current.Value;
            if (e.TryGetCurrentPattern(TextPattern.Pattern, out p)) return ((TextPattern)p).DocumentRange.GetText(4096);
        }
        catch { }
        try { return e.Current.Name; } catch { return ""; }
    }

    // Selected state for radio / checkbox / tab items. Needed to verify a pick landed.
    public static bool IsSelected(AutomationElement e)
    {
        object p;
        try
        {
            if (e.TryGetCurrentPattern(SelectionItemPattern.Pattern, out p))
                return ((SelectionItemPattern)p).Current.IsSelected;
            if (e.TryGetCurrentPattern(TogglePattern.Pattern, out p))
                return ((TogglePattern)p).Current.ToggleState == ToggleState.On;
        }
        catch { }
        return false;
    }

    // The web page root inside a Chromium window. Everything a web task needs hangs here.
    public static AutomationElement DocumentOf(AutomationElement win)
    {
        if (win == null) return null;
        var cond = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Document);
        try
        {
            var d = win.FindFirst(TreeScope.Descendants, cond);
            if (d != null) return d;
        }
        catch { }
        return win;
    }

    // Flat dump of a subtree in tree order. Chromium pages are big, so callers cap it.
    public static List<AutomationElement> Descendants(AutomationElement scope, int max)
    {
        var res = new List<AutomationElement>();
        if (scope == null) return res;
        AutomationElementCollection all;
        try { all = scope.FindAll(TreeScope.Descendants, Condition.TrueCondition); }
        catch { return res; }
        foreach (AutomationElement e in all)
        {
            if (res.Count >= max) break;
            res.Add(e);
        }
        return res;
    }
}
