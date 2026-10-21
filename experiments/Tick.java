import java.util.*;

// Rough stand-in for a game tick: value noise over a 16x16x384 "chunk",
// a HashMap keyed by packed block positions, and object churn.
public class Tick {
    static double noise(int x, int y, int z) {
        long h = x * 73856093L ^ y * 19349663L ^ z * 83492791L;
        h ^= (h >>> 13); h *= 0x5bd1e995L; h ^= (h >>> 15);
        return (h & 0xffff) / 65535.0;
    }

    static long chunk(int cx, int cz, Map<Long, int[]> map) {
        long sum = 0;
        for (int x = 0; x < 16; x++)
            for (int z = 0; z < 16; z++)
                for (int y = 0; y < 384; y += 2) {
                    double d = noise(cx * 16 + x, y, cz * 16 + z) * 0.6 + noise(x >> 2, y >> 2, z >> 2) * 0.4;
                    if (d > 0.5) {
                        long key = ((long) (cx * 16 + x) << 38) | ((long) (cz * 16 + z) << 12) | y;
                        map.put(key, new int[] { x, y, z });
                        sum += y;
                    }
                }
        return sum;
    }

    public static void main(String[] a) {
        int rounds = Integer.parseInt(a.length > 0 ? a[0] : "20");
        long total = 0;
        for (int r = 0; r < rounds; r++) {
            long t = System.nanoTime();
            Map<Long, int[]> map = new HashMap<>();
            for (int c = 0; c < 4; c++) total += chunk(r * 4 + c, r, map);
            List<Long> keys = new ArrayList<>(map.keySet());
            Collections.sort(keys);
            total += keys.size();
            System.out.printf("round %d: %.1f ms%n", r, (System.nanoTime() - t) / 1e6);
        }
        System.out.println("checksum " + total);
    }
}
