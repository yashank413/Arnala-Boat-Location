from django.contrib import admin

# Register your models here.
from .models import BoatLocation

@admin.register(BoatLocation)
class BoatLocationAdmin(admin.ModelAdmin):
    list_display = ('latitude','longitude','timestamp')
    ordering = ('-timestamp',)
    readonly_fields = ('timestamp',)
