import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.List;

// Dumps "package\tlabel\tuser|system" for every installed application, in ONE
// app_process run (no per-app shell spawn). Pure reflection so it compiles
// without android.jar. Intended: CLASSPATH=applist.dex app_process / AppList
public class AppList {
    public static void main(String[] args) throws Exception {
        // systemMain() builds an ActivityThread whose Handler needs a Looper.
        Class.forName("android.os.Looper").getMethod("prepareMainLooper").invoke(null);
        Class<?> at = Class.forName("android.app.ActivityThread");
        Object thread = at.getMethod("systemMain").invoke(null);
        Object ctx = at.getMethod("getSystemContext").invoke(thread);

        Object pm = ctx.getClass().getMethod("getPackageManager").invoke(ctx);
        Class<?> pmClass = Class.forName("android.content.pm.PackageManager");
        Class<?> aiClass = Class.forName("android.content.pm.ApplicationInfo");

        Class<?> flagsClass = Class.forName("android.content.pm.PackageManager$ApplicationInfoFlags");
        Object flags = flagsClass.getMethod("of", long.class).invoke(null, 0L);
        Method listApps = pmClass.getMethod("getInstalledApplications", flagsClass);
        List<?> apps = (List<?>) listApps.invoke(pm, flags);

        Method getLabel = pmClass.getMethod("getApplicationLabel", aiClass);
        Field pkgField = aiClass.getField("packageName");
        Field flagsField = aiClass.getField("flags");
        final int FLAG_SYSTEM = 1; // ApplicationInfo.FLAG_SYSTEM

        StringBuilder sb = new StringBuilder(1 << 16);
        for (Object ai : apps) {
            String pkg = (String) pkgField.get(ai);
            String label;
            try {
                CharSequence cs = (CharSequence) getLabel.invoke(pm, ai);
                label = cs == null ? pkg : cs.toString();
            } catch (Throwable t) {
                label = pkg;
            }
            label = label.replace('\t', ' ').replace('\n', ' ').replace('\r', ' ').trim();
            if (label.isEmpty()) label = pkg;
            int fl = flagsField.getInt(ai);
            sb.append(pkg).append('\t').append(label).append('\t')
              .append((fl & FLAG_SYSTEM) != 0 ? "system" : "user").append('\n');
        }
        System.out.print(sb);
    }
}
